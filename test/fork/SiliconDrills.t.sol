// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {KyznUsdOracle} from "../../src/silicon/KyznUsdOracle.sol";
import {MarketCalendar} from "../../src/silicon/MarketCalendar.sol";
import {SiliconSynth} from "../../src/silicon/SiliconSynth.sol";
import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {StockIndexFeed} from "../../src/silicon/StockIndexFeed.sol";
import {IUniswapV2PairTwap} from "../../src/silicon/interfaces/IUniswapV2PairTwap.sol";
import {TestnetFeed} from "../../script/testnet/TestnetFeed.sol";
import {TestnetUsdg} from "../../script/testnet/TestnetUsdg.sol";

/// The Silicon drills (design spec, "Testnet and drills") against the real testnet deployment of
/// Robinhood Chain testnet (46630), on a fork with time warp. Every address comes from
/// deployments/46630.json. The deployer owns the stand-in feeds, the USDG stand-in, the vault and
/// the index feeds and is their guardian, so it is pranked for owner and guardian actions; nothing
/// is sent to the chain. Skipped unless TESTNET_RPC_URL names a Robinhood Chain testnet RPC (or an
/// anvil fork of it started with --chain-id 46630):
///   TESTNET_RPC_URL=https://rpc.testnet.chain.robinhood.com \
///     forge test --match-path test/fork/SiliconDrills.t.sol -vv
/// The report is docs/superpowers/silicon-drills.md.
///
/// Each test starts from the same setup: the fork is warped to the next Monday 15:00 UTC whose
/// Monday, Tuesday and Wednesday are regular days on the deployed calendar; ETH/USD and the seven
/// stock stand-ins are stamped again at their current answers; a buyer takes $KYZN from the
/// testnet pool with ETH (the pool holds very little WETH, so the buy also lifts $KYZN to a price at
/// which a position can hold the minimum debt); the oracle records an observation every short
/// window until its price is available and the long average spans a long window; closed markets
/// are opened. Time then moves in steps of one short window with an observation at each, and the
/// feeds are stamped again every 6 hours, so that only what a drill changes can stop a price.
contract SiliconDrillsForkTest is Test {
    uint256 internal constant CHAIN_ID = 46630;
    string internal constant DEPLOYMENT = "deployments/46630.json";
    string internal constant CALENDAR_FILE = "script/market-calendar.json";
    uint256 internal constant STOCKS = 7;
    uint256 internal constant MARKETS = 4;
    /// Market ids: Design (NVDA, AMD) and Memory (MU, SNDK).
    uint256 internal constant DESIGN = 0;
    uint256 internal constant MEMORY = 1;
    /// The stand-ins and the oracle's ETH/USD are stamped again this often while time moves.
    uint256 internal constant RESTAMP_EVERY = 6 hours;
    /// The buyer's ETH, in multiples of the pool's WETH reserve.
    uint256 internal constant BUY_MULTIPLE = 60;
    /// Of the pool's $KYZN reserve, what the fall's sale adds to it after the sell tax: the pool's
    /// price falls to 1 / 1.3^2, about 59% of what it was.
    uint256 internal constant FALL_SALE_BPS = 3_000;
    uint256 internal constant BPS = 10_000;
    uint256 internal constant RATIO_BPS = 15_000;

    // ---------------------------------------------------------------- the deployment

    address internal deployer;
    IERC20 internal kyzn;
    IUniswapV2PairTwap internal pair;
    IUniswapV2Router02 internal router;
    address internal weth;
    TestnetFeed internal ethUsd;
    SiliconVault internal vault;
    KyznUsdOracle internal oracle;
    MarketCalendar internal calendar;
    TestnetUsdg internal usdg;
    address internal feeRouter;
    string[STOCKS] internal tickers = ["NVDA", "AMD", "MU", "SNDK", "TSM", "INTC", "ASML"];
    TestnetFeed[STOCKS] internal stock;
    StockIndexFeed[MARKETS] internal feed;
    SiliconSynth[MARKETS] internal synth;
    uint256 internal shortWindow;
    uint256 internal longWindow;

    // ---------------------------------------------------------------- the drill

    address internal whale = makeAddr("whale"); // bought the $KYZN every position holds
    address internal alice = makeAddr("alice"); // the position each drill works on
    address internal bob = makeAddr("bob"); // the bidder
    address internal carol = makeAddr("carol"); // a minter
    address internal keeper = makeAddr("keeper"); // starts and closes auctions

    uint256 internal forkBlock;
    uint256 internal forkTime;
    /// 00:00 UTC of the Monday the drills run on.
    uint256 internal monday;
    uint256 internal lastRestamp;
    /// Stand-ins the restamps leave alone (a component left to go stale).
    mapping(address => bool) internal frozen;

    function setUp() public {
        string memory url = vm.envOr("TESTNET_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true, "TESTNET_RPC_URL is not set");
        vm.createSelectFork(url);
        assertEq(block.chainid, CHAIN_ID, "the fork is not Robinhood Chain testnet");
        forkBlock = block.number;
        forkTime = block.timestamp;
        _load();

        monday = _nextMonday();
        vm.warp(monday + 15 hours);
        assertTrue(calendar.isMintWindow(block.timestamp), "Monday 15:00 UTC is in the window");
        _restamp();
        _buyKyzn();
        oracle.update();
        _buildHistory();
        _openMarkets();

        console2.log("fork block                ", forkBlock);
        console2.log("fork timestamp            ", forkTime);
        console2.log("drill Monday (UTC day)    ", monday / 1 days);
        console2.log("$KYZN/USD (1e18)          ", oracle.price());
    }

    // ================================================================ a. a mint in the window

    /// Inside the window, on every market: deposit $KYZN and USDG (60% $KYZN), mint twice the
    /// minimum debt at 160%. A mint below the minimum debt is refused.
    function test_drill_a_mint_inside_the_window() public {
        assertTrue(calendar.isMintWindow(block.timestamp), "in the window");
        for (uint256 id; id < MARKETS; ++id) {
            assertTrue(feed[id].isFresh(), "the index is fresh in the window");
            uint256 amount = vault.market(id).minDebt * 2;
            (uint256 k, uint256 u) = _collateralFor(id, amount, 16_000, 6_000);
            _fund(alice, k, u);
            vm.startPrank(alice);
            kyzn.approve(address(vault), k);
            usdg.approve(address(vault), u);
            vm.expectEmit(address(vault));
            emit SiliconVault.Deposited(id, alice, k, u);
            vault.deposit(id, k, u);
            vm.stopPrank();

            uint256 fee = _mintFee(id, amount);
            vm.expectEmit(address(vault));
            emit SiliconVault.Minted(id, alice, amount, fee);
            vm.prank(alice);
            vault.mint(id, amount);

            assertEq(synth[id].balanceOf(alice), amount, "the synth minted");
            assertApproxEqAbs(vault.debtOf(id, alice), amount + fee, 2, "the debt is the amount and the fee");
            (uint256 collateral, uint256 debtValue, uint256 ratio, uint256 share) = vault.health(id, alice);
            assertGe(ratio, RATIO_BPS, "at or above 150%");
            assertGe(share, 5_000, "at least 50% $KYZN");
            _assertBooks(id);
            console2.log(synth[id].symbol(), "minted (1e18)", amount);
            console2.log("  collateral USD (1e18)   ", collateral);
            console2.log("  debt USD (1e18)         ", debtValue);
            console2.log("  ratio / $KYZN share bps ", ratio, share);
        }

        // Below the minimum debt: refused.
        uint256 small = vault.market(MEMORY).minDebt / 2;
        (uint256 k2, uint256 u2) = _collateralFor(MEMORY, small, 16_000, 6_000);
        _deposit(carol, MEMORY, k2, u2);
        vm.prank(carol);
        vm.expectPartialRevert(SiliconVault.DebtBelowMinimum.selector);
        vault.mint(MEMORY, small);
    }

    // ================================================================ b. outside the window

    /// The same Monday at 20:00 UTC the window has closed: a mint is refused StalePrice while the
    /// prices are otherwise good (fresh enough to liquidate on). On an exchange holiday from the
    /// calendar file, at 15:00 UTC, the same.
    function test_drill_b_mint_refused_outside_the_window_and_on_a_holiday() public {
        uint256 amount = vault.market(MEMORY).minDebt * 2;
        (uint256 k, uint256 u) = _collateralFor(MEMORY, amount, 16_000, 6_000);
        _deposit(alice, MEMORY, k, u);

        _advanceTo(monday + 20 hours);
        assertFalse(calendar.isMintWindow(block.timestamp), "20:00 UTC is outside the window");
        assertTrue(feed[MEMORY].isFreshForLiquidation(), "the prices themselves are good");
        assertFalse(feed[MEMORY].isFresh(), "but not for a mint");
        oracle.price(); // available
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed[MEMORY])));
        vault.mint(MEMORY, amount);
        console2.log("refused at (unix)         ", block.timestamp);

        // The first exchange holiday after the drill week.
        uint256 holiday = _nextClosedDay(block.timestamp / 1 days);
        assertEq(
            uint256(calendar.dayKind(holiday)), uint256(MarketCalendar.DayKind.Closed), "the calendar marks it closed"
        );
        uint256 weekday = (holiday + 4) % 7;
        assertTrue(weekday >= 1 && weekday <= 5, "a weekday");
        _resumeAt(holiday * 1 days + 15 hours);
        assertFalse(calendar.isMintWindow(block.timestamp), "no window on a holiday");
        assertTrue(feed[MEMORY].isFreshForLiquidation(), "the prices themselves are good");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed[MEMORY])));
        vault.mint(MEMORY, amount);
        (uint256 kyznLeft, uint256 usdgLeft, uint256 shares) = vault.positions(MEMORY, alice);
        assertEq(shares, 0, "nothing minted");
        assertEq(kyznLeft, k);
        assertEq(usdgLeft, u);
        console2.log("holiday (UTC day)         ", holiday);
        console2.log("refused at (unix)         ", block.timestamp);
    }

    // ================================================================ c. a fall and a full bid

    /// $KYZN falls 40% in the pool and holds a short window: Alice's position (160%, 60% $KYZN)
    /// falls below 150% and goes to auction; Bob's one bid repays the debt and the penalty, and
    /// the collateral left returns to her position, from which she withdraws it.
    function test_drill_c_fall_starts_an_auction_and_a_full_bid_closes_it() public {
        (uint256 aid, uint256 debt, uint256 penalty) = _fallAndStart();
        SiliconVault.Auction memory a = vault.auction(aid);
        uint256 owed = debt + penalty;
        uint256 lot = vault.auctionPrice(aid);
        assertGt(lot, owed, "the lot is worth more than the debt and the penalty");
        uint256 kyznOut = Math.mulDiv(a.kyzn, owed, lot);
        uint256 usdgOut = Math.mulDiv(a.usdg, owed, lot);
        uint256 bobSynth = synth[MEMORY].balanceOf(bob);
        uint256 routerSynth = synth[MEMORY].balanceOf(feeRouter);
        uint256 auctionDebt = vault.market(MEMORY).auctionDebt;

        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionBid(aid, bob, owed, kyznOut, usdgOut);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionClosed(aid, alice, a.kyzn - kyznOut, a.usdg - usdgOut, 0);
        vm.prank(bob);
        (uint256 paid,,) = vault.bid(aid, type(uint256).max);

        assertEq(paid, owed, "one bid paid the debt and the penalty");
        assertEq(bobSynth - synth[MEMORY].balanceOf(bob), owed, "from the bidder");
        assertEq(synth[MEMORY].balanceOf(feeRouter) - routerSynth, penalty, "the penalty to the fee router");
        assertEq(auctionDebt - vault.market(MEMORY).auctionDebt, debt, "the debt burned");
        assertEq(kyzn.balanceOf(bob), kyznOut, "the bidder's $KYZN");
        assertEq(usdg.balanceOf(bob), usdgOut, "the bidder's USDG");
        assertEq(vault.auction(aid).account, address(0), "closed");
        _assertReturned(a.kyzn - kyznOut, a.usdg - usdgOut);
        _assertBooks(MEMORY);
        console2.log("lot at the start (synth)  ", lot);
        console2.log("paid (synth)              ", paid);
        console2.log("collateral left: $KYZN    ", a.kyzn - kyznOut);
        console2.log("collateral left: USDG     ", a.usdg - usdgOut);
    }

    // ================================================================ d. a partial bid

    /// The same auction taken in two bids: half of what it is owed (debt only), then, two minutes
    /// later at a lower price, the rest, which repays the debt and the penalty and closes it.
    function test_drill_d_partial_bid_then_the_rest() public {
        (uint256 aid, uint256 debt, uint256 penalty) = _fallAndStart();
        uint256 routerSynth = synth[MEMORY].balanceOf(feeRouter);
        SiliconVault.Auction memory a = vault.auction(aid);
        uint256 first = (debt + penalty) / 2;
        assertLt(first, debt, "the first bid repays debt only");
        uint256 lot1 = vault.auctionPrice(aid);
        uint256 kyznOut1 = Math.mulDiv(a.kyzn, first, lot1);
        uint256 usdgOut1 = Math.mulDiv(a.usdg, first, lot1);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionBid(aid, bob, first, kyznOut1, usdgOut1);
        vm.prank(bob);
        vault.bid(aid, first);

        a = vault.auction(aid);
        assertEq(a.account, alice, "still running");
        assertEq(a.debt, debt - first, "the bid burned debt");
        assertEq(a.penalty, penalty, "the penalty waits");

        vm.warp(block.timestamp + 2 minutes);
        uint256 lot2 = vault.auctionPrice(aid);
        uint256 rest = a.debt + a.penalty;
        assertGt(lot2, rest, "what is left still covers the rest");
        uint256 kyznOut2 = Math.mulDiv(a.kyzn, rest, lot2);
        uint256 usdgOut2 = Math.mulDiv(a.usdg, rest, lot2);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionBid(aid, bob, rest, kyznOut2, usdgOut2);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionClosed(aid, alice, a.kyzn - kyznOut2, a.usdg - usdgOut2, 0);
        vm.prank(bob);
        vault.bid(aid, type(uint256).max);

        assertEq(synth[MEMORY].balanceOf(feeRouter) - routerSynth, penalty, "the penalty to the fee router");
        assertEq(kyzn.balanceOf(bob), kyznOut1 + kyznOut2, "the bidder's $KYZN");
        _assertReturned(a.kyzn - kyznOut2, a.usdg - usdgOut2);
        _assertBooks(MEMORY);
        console2.log("first bid (synth)         ", first);
        console2.log("lot after 2 minutes       ", lot2);
        console2.log("second bid (synth)        ", rest);
        console2.log("collateral left: $KYZN    ", a.kyzn - kyznOut2);
    }

    // ================================================================ e. an unsold auction

    /// No one bids. At its end the auction restarts once at that day's prices; at the second end
    /// the debt is bad debt and the collateral goes to the fee router.
    function test_drill_e_unsold_auction_restarts_then_records_bad_debt() public {
        (uint256 aid, uint256 debt,) = _fallAndStart();
        SiliconVault.Auction memory a = vault.auction(aid);
        uint256 endsAt = a.startedAt + a.duration;
        assertEq(a.duration, 600, "the testnet auction runs 10 minutes");

        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionNotEnded.selector, aid, endsAt));
        vault.closeAuction(aid);
        _advanceTo(endsAt);
        assertEq(vault.auctionPrice(aid), 0, "ended");
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionEnded.selector, aid));
        vault.bid(aid, 1);

        (uint256 synthPrice,) = feed[MEMORY].latestPrice();
        uint256 start = (BPS + vault.auctionStartPremiumBps()) * 1e18;
        uint256 kyznStart = Math.mulDiv(oracle.price(), start, synthPrice * BPS);
        uint256 usdgStart = Math.mulDiv(vault.usdgScale() * 1e18, start, synthPrice * BPS);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionRestarted(aid, kyznStart, usdgStart);
        vm.prank(keeper);
        vault.closeAuction(aid);
        SiliconVault.Auction memory r = vault.auction(aid);
        assertTrue(r.restarted, "restarted");
        assertEq(r.startedAt, block.timestamp, "a new clock");
        assertEq(r.debt, a.debt, "the same debt");
        assertEq(r.penalty, a.penalty, "the same penalty");
        assertEq(r.kyzn, a.kyzn, "the same collateral");

        _advanceTo(r.startedAt + r.duration);
        uint256 routerKyzn = kyzn.balanceOf(feeRouter);
        uint256 routerUsdg = usdg.balanceOf(feeRouter);
        uint256 badDebt = vault.market(MEMORY).badDebt;
        vm.expectEmit(address(vault));
        emit SiliconVault.BadDebtRecorded(MEMORY, aid, debt);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionClosed(aid, feeRouter, a.kyzn, a.usdg, debt);
        vm.prank(keeper);
        vault.closeAuction(aid);

        assertEq(vault.market(MEMORY).badDebt - badDebt, debt, "the debt is bad debt");
        assertEq(kyzn.balanceOf(feeRouter) - routerKyzn, a.kyzn, "the $KYZN to the fee router");
        assertEq(usdg.balanceOf(feeRouter) - routerUsdg, a.usdg, "the USDG to the fee router");
        assertEq(vault.auction(aid).account, address(0), "closed");
        (uint256 k, uint256 u, uint256 shares) = vault.positions(MEMORY, alice);
        assertEq(k + u + shares, 0, "nothing returns to the position");
        _assertBooks(MEMORY);
        console2.log("restart: $KYZN start price", kyznStart);
        console2.log("bad debt (synth)          ", debt);
    }

    // ================================================================ f. a 35% jump

    /// MU's stand-in prints a round 35% below the last: the breaker stops the Memory index for
    /// mints and liquidations alike, until the guardian clears that round; then mints work again.
    function test_drill_f_jump_trips_the_breaker_until_the_guardian_clears_it() public {
        uint256 amount = vault.market(MEMORY).minDebt * 2;
        _open(alice, MEMORY, amount, 16_000, 6_000);
        (uint256 k, uint256 u) = _collateralFor(MEMORY, amount, 16_000, 6_000);
        _deposit(carol, MEMORY, k, u);

        StockIndexFeed f = feed[MEMORY];
        TestnetFeed mu = _componentFeed(MEMORY, 0);
        assertEq(address(mu), address(stock[2]), "Memory's first component is MU");
        (, int256 answer,,,) = mu.latestRoundData();
        vm.prank(deployer);
        mu.set(answer * 65 / 100, block.timestamp);
        uint80 jumpRound = mu.roundId();
        f.sync();
        assertTrue(f.jumped(0), "the breaker latched");
        assertLt(f.checkedRound(0), jumpRound, "sync stops before the jump");
        assertFalse(f.isFresh(), "no mints");
        assertFalse(f.isFreshForLiquidation(), "no liquidations");

        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(f)));
        vault.mint(MEMORY, amount);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(f)));
        vault.startAuction(alice, MEMORY);

        vm.expectEmit(address(f));
        emit StockIndexFeed.JumpCleared(0, jumpRound);
        vm.prank(deployer);
        f.clearJump(0, jumpRound);
        assertFalse(f.jumped(0), "cleared");
        assertTrue(f.isFresh(), "fresh again");

        uint256 fee = _mintFee(MEMORY, amount);
        vm.expectEmit(address(vault));
        emit SiliconVault.Minted(MEMORY, carol, amount, fee);
        vm.prank(carol);
        vault.mint(MEMORY, amount);
        // Liquidations read the price again: Alice is healthy at it.
        (,, uint256 ratio,) = vault.health(MEMORY, alice);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NotLiquidatable.selector, ratio, RATIO_BPS));
        vault.startAuction(alice, MEMORY);
        _assertBooks(MEMORY);
        (uint256 index,) = f.latestPrice();
        console2.log("MU before (1e8)           ", answer);
        console2.log("MU jump round (1e8)       ", answer * 65 / 100);
        console2.log("jump round cleared        ", uint256(jumpRound));
        console2.log("Memory index after (1e18) ", index);
    }

    // ================================================================ g. a quantity correction

    /// A quantity correction (a stock split needs none: the feed's price includes the token's
    /// multiplier). NVDA's feed is to quote a new basis at half the price, as a token migrated 2
    /// for 1 would: the owner queues twice the quantity, the new basis prints at half the price
    /// (a jump), the guardian cannot clear it while the quantity waits, anyone applies it after 24
    /// hours, then the guardian clears the round and the index is where it was.
    function test_drill_g_quantity_correction_queued_applied_after_24_hours_then_cleared() public {
        StockIndexFeed f = feed[DESIGN];
        TestnetFeed nvda = _componentFeed(DESIGN, 0);
        assertEq(address(nvda), address(stock[0]), "Design's first component is NVDA");
        (,, uint256 quantity) = f.component(0);
        (uint256 before,) = f.latestPrice();
        uint256 doubled = quantity * 2;
        uint256 due = block.timestamp + f.QUANTITY_DELAY();

        vm.expectEmit(address(f));
        emit StockIndexFeed.QuantityQueued(0, doubled, due);
        vm.prank(deployer);
        f.queueQuantity(0, doubled);

        // The new basis prints a little later: half the price.
        _advanceTo(block.timestamp + shortWindow);
        (, int256 answer,,,) = nvda.latestRoundData();
        vm.prank(deployer);
        nvda.set(answer / 2, block.timestamp);
        uint80 printRound = nvda.roundId();
        f.sync();
        assertTrue(f.jumped(0), "the print is a jump");
        assertFalse(f.isFresh(), "no mints");
        assertFalse(f.isFreshForLiquidation(), "no liquidations");
        (uint256 atPrint,) = f.latestPrice();

        vm.prank(deployer);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityPending.selector, 0));
        f.clearJump(0, printRound);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityNotDue.selector, due));
        f.applyQuantity(0);

        _advanceTo(due);
        vm.expectEmit(address(f));
        emit StockIndexFeed.QuantityApplied(0, doubled);
        vm.prank(keeper);
        f.applyQuantity(0);
        assertTrue(f.needsClear(0), "stopped until cleared");
        assertTrue(f.jumped(0));
        assertFalse(f.isFresh());

        uint80 latest = nvda.roundId();
        vm.expectEmit(address(f));
        emit StockIndexFeed.JumpCleared(0, latest);
        vm.prank(deployer);
        f.clearJump(0, latest);
        assertFalse(f.jumped(0), "cleared");
        assertTrue(f.isFresh(), "mints again");
        (,, uint256 applied) = f.component(0);
        assertEq(applied, doubled);
        (uint256 afterCorrection,) = f.latestPrice();
        assertApproxEqRel(afterCorrection, before, 0.005e18, "the index is continuous across the correction");

        _open(carol, DESIGN, vault.market(DESIGN).minDebt * 2, 16_000, 6_000);
        _assertBooks(DESIGN);
        console2.log("Design index before (1e18)", before);
        console2.log("at the print, unapplied   ", atPrint);
        console2.log("after apply and clear     ", afterCorrection);
    }

    // ================================================================ h. a stale component

    /// SNDK's stand-in was last updated Tuesday 09:00 UTC; on Wednesday at 15:00, in the window,
    /// it is 30 hours old: mints stop, liquidations do not. MU rising 25% (inside the breaker's
    /// limit) takes Alice's position (155%) below 150%, and startAuction succeeds.
    function test_drill_h_stale_component_stops_mints_but_not_liquidations() public {
        uint256 amount = vault.market(MEMORY).minDebt * 2;
        _open(alice, MEMORY, amount, 15_500, 6_000);
        StockIndexFeed f = feed[MEMORY];
        TestnetFeed mu = _componentFeed(MEMORY, 0);
        TestnetFeed sndk = _componentFeed(MEMORY, 1);
        assertEq(address(sndk), address(stock[3]), "Memory's second component is SNDK");

        _advanceTo(monday + 1 days + 9 hours);
        _restamp(); // SNDK's last update
        frozen[address(sndk)] = true;
        _advanceTo(monday + 2 days + 15 hours);
        _restamp(); // every other feed is fresh
        (,,, uint256 sndkAt,) = sndk.latestRoundData();
        assertEq(block.timestamp - sndkAt, 30 hours, "SNDK is 30 hours old");
        assertTrue(calendar.isMintWindow(block.timestamp), "in the window");
        assertFalse(f.jumped(0) || f.jumped(1) || f.paused(), "nothing else stops the index");
        assertFalse(f.isFresh(), "too old to mint on");
        assertTrue(f.isFreshForLiquidation(), "young enough to liquidate on");

        (uint256 k, uint256 u) = _collateralFor(MEMORY, amount, 16_000, 6_000);
        _deposit(carol, MEMORY, k, u);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(f)));
        vault.mint(MEMORY, amount);

        (, int256 muAnswer,,,) = mu.latestRoundData();
        vm.prank(deployer);
        mu.set(muAnswer * 125 / 100, block.timestamp);
        f.sync();
        assertFalse(f.jumped(0), "25% is inside the breaker's limit");
        (,, uint256 ratio,) = vault.health(MEMORY, alice);
        assertLt(ratio, RATIO_BPS, "below 150%");

        uint256 aid = _start(alice, MEMORY);
        assertEq(vault.auction(aid).account, alice, "the auction runs");
        _assertBooks(MEMORY);
        console2.log("SNDK age (s)              ", block.timestamp - sndkAt);
        console2.log("ratio before the auction  ", ratio);
        console2.log("auction id                ", aid);
    }

    // ================================================================ drill helpers

    /// Alice at 160% (60% $KYZN) and Bob, the bidder, with four times her synth at 400%, in the
    /// Memory market; then $KYZN falls 40% and the keeper starts Alice's auction.
    function _fallAndStart() internal returns (uint256 aid, uint256 debt, uint256 penalty) {
        uint256 amount = vault.market(MEMORY).minDebt * 8 / 5;
        _open(alice, MEMORY, amount, 16_000, 6_000);
        _open(bob, MEMORY, amount * 4, 40_000, 6_000);
        (uint256 before, uint256 fallen) = _fallKyzn();
        (,, uint256 ratio,) = vault.health(MEMORY, alice);
        assertLt(ratio, RATIO_BPS, "below 150%");
        console2.log("$KYZN/USD before (1e18)   ", before);
        console2.log("$KYZN/USD after (1e18)    ", fallen);
        console2.log("fall (bps)                ", BPS - fallen * BPS / before);
        console2.log("ratio after the fall (bps)", ratio);
        aid = _start(alice, MEMORY);
        SiliconVault.Auction memory a = vault.auction(aid);
        debt = a.debt;
        penalty = a.penalty;
        console2.log("auction debt (synth)      ", debt);
        console2.log("auction penalty (synth)   ", penalty);
    }

    /// The keeper puts `account`'s position in market `id` up for auction; checks the event.
    function _start(address account, uint256 id) internal returns (uint256 aid) {
        aid = vault.auctionCount();
        (uint256 k, uint256 u,) = vault.positions(id, account);
        uint256 debt = vault.debtOf(id, account);
        uint256 penalty = debt * vault.market(id).liquidationPenaltyBps / BPS;
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionStarted(aid, id, account, k, u, debt, penalty);
        vm.prank(keeper);
        assertEq(vault.startAuction(account, id), aid);
    }

    /// Sells $KYZN into the testnet pool so its price falls to about 59%, with an observation at
    /// the moment of the sale, then holds it one short window: the short average, and so the
    /// oracle's price, is then all after the fall. Returns the oracle's price before and after.
    function _fallKyzn() internal returns (uint256 before, uint256 fallen) {
        (uint256 lastObservation,) = oracle.observation(0);
        if (lastObservation != block.timestamp) {
            if (oracle.due()) oracle.update();
            else _advanceTo(lastObservation + shortWindow);
        }
        before = oracle.price();
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 kyznReserve = pair.token0() == address(kyzn) ? r0 : r1;
        uint256 tax = _sellTax();
        uint256 sold = Math.mulDiv(kyznReserve * FALL_SALE_BPS / BPS, BPS, BPS - tax);
        vm.startPrank(whale);
        kyzn.approve(address(router), sold);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            sold, 0, _path(address(kyzn), weth), whale, block.timestamp
        );
        vm.stopPrank();
        _advanceTo(block.timestamp + shortWindow);
        fallen = oracle.price();
        assertLe(fallen * BPS, before * 6_000, "$KYZN fell at least 40%");
    }

    /// The $KYZN tax on a sale to the pool, in basis points: sellTaxBps() on the current token,
    /// taxBps() (one rate for buys and sells) on the token the testnet runs.
    function _sellTax() internal view returns (uint256) {
        (bool ok, bytes memory data) = address(kyzn).staticcall(abi.encodeWithSignature("sellTaxBps()"));
        if (!ok || data.length != 32) {
            (ok, data) = address(kyzn).staticcall(abi.encodeWithSignature("taxBps()"));
        }
        require(ok && data.length == 32, "the $KYZN sell tax cannot be read");
        return abi.decode(data, (uint256));
    }

    /// Alice's position after her auction closed with its debt repaid: no debt, the collateral
    /// left credited, and she withdraws it without a price.
    function _assertReturned(uint256 kyznLeft, uint256 usdgLeft) internal {
        (uint256 k, uint256 u, uint256 shares) = vault.positions(MEMORY, alice);
        assertEq(shares, 0, "no debt");
        assertEq(k, kyznLeft, "the $KYZN left returned");
        assertEq(u, usdgLeft, "the USDG left returned");
        uint256 kyznBefore = kyzn.balanceOf(alice);
        uint256 usdgBefore = usdg.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(MEMORY, k, u);
        assertEq(kyzn.balanceOf(alice) - kyznBefore, k);
        assertEq(usdg.balanceOf(alice) - usdgBefore, u);
    }

    /// Every synth in circulation is owed by a position, a running auction, or is bad debt.
    function _assertBooks(uint256 id) internal view {
        SiliconVault.Market memory m = vault.market(id);
        assertEq(synth[id].totalSupply(), m.totalDebt + m.auctionDebt + m.badDebt, "synth supply = debt owed");
    }

    // ================================================================ positions

    /// The $KYZN and USDG that put a mint of `amount` at `ratioBps`, with `kyznShareBps` of the
    /// collateral value in $KYZN, at the prices now.
    function _collateralFor(uint256 id, uint256 amount, uint256 ratioBps, uint256 kyznShareBps)
        internal
        view
        returns (uint256 kyznAmount, uint256 usdgAmount)
    {
        (uint256 synthPrice,) = feed[id].latestPrice();
        uint256 debtValue = Math.mulDiv(amount + _mintFee(id, amount), synthPrice, 1e18, Math.Rounding.Ceil);
        uint256 collateral = debtValue * ratioBps / BPS;
        uint256 kyznValue = collateral * kyznShareBps / BPS;
        kyznAmount = Math.mulDiv(kyznValue, 1e18, oracle.price(), Math.Rounding.Ceil);
        usdgAmount = (collateral - kyznValue) / vault.usdgScale();
    }

    /// Funds `who` and deposits `kyznAmount` $KYZN and `usdgAmount` USDG in market `id`.
    function _deposit(address who, uint256 id, uint256 kyznAmount, uint256 usdgAmount) internal {
        _fund(who, kyznAmount, usdgAmount);
        vm.startPrank(who);
        kyzn.approve(address(vault), kyznAmount);
        usdg.approve(address(vault), usdgAmount);
        vault.deposit(id, kyznAmount, usdgAmount);
        vm.stopPrank();
    }

    /// A position minting `amount` at `ratioBps` with `kyznShareBps` $KYZN; checks the Minted event.
    function _open(address who, uint256 id, uint256 amount, uint256 ratioBps, uint256 kyznShareBps) internal {
        (uint256 k, uint256 u) = _collateralFor(id, amount, ratioBps, kyznShareBps);
        _deposit(who, id, k, u);
        vm.expectEmit(address(vault));
        emit SiliconVault.Minted(id, who, amount, _mintFee(id, amount));
        vm.prank(who);
        vault.mint(id, amount);
    }

    /// $KYZN from the buyer (a wallet-to-wallet transfer: no tax) and USDG minted by the deployer.
    function _fund(address who, uint256 kyznAmount, uint256 usdgAmount) internal {
        vm.prank(whale);
        assertTrue(kyzn.transfer(who, kyznAmount));
        vm.prank(deployer);
        usdg.mint(who, usdgAmount);
    }

    function _mintFee(uint256 id, uint256 amount) internal view returns (uint256) {
        return Math.mulDiv(amount, vault.market(id).mintFeeBps, BPS, Math.Rounding.Ceil);
    }

    function _componentFeed(uint256 id, uint256 i) internal view returns (TestnetFeed) {
        (address f,,) = feed[id].component(i);
        return TestnetFeed(f);
    }

    // ================================================================ time and prices

    /// Moves time to `t` in steps of at most one short window, recording an observation at each
    /// and stamping the feeds again every RESTAMP_EVERY.
    function _advanceTo(uint256 t) internal {
        while (block.timestamp < t) {
            uint256 step = Math.min(shortWindow, t - block.timestamp);
            vm.warp(block.timestamp + step);
            if (block.timestamp - lastRestamp >= RESTAMP_EVERY) _restamp();
            oracle.update();
        }
    }

    /// Jumps to a long window and a short window before `t`, stamps the feeds, and records
    /// observations up to `t`, so the oracle has a price again at `t` after a gap.
    function _resumeAt(uint256 t) internal {
        vm.warp(t - longWindow - shortWindow);
        _restamp();
        oracle.update();
        _advanceTo(t);
        oracle.price(); // available again
    }

    /// Stamps ETH/USD and every stock stand-in not frozen again at its current answer, dated now
    /// (a new round each), and has every index feed record the rounds.
    function _restamp() internal {
        vm.startPrank(deployer);
        _stamp(ethUsd);
        for (uint256 i; i < STOCKS; ++i) {
            if (!frozen[address(stock[i])]) _stamp(stock[i]);
        }
        vm.stopPrank();
        for (uint256 id; id < MARKETS; ++id) {
            feed[id].sync();
        }
        lastRestamp = block.timestamp;
    }

    function _stamp(TestnetFeed f) internal {
        (, int256 answer,,,) = f.latestRoundData();
        f.set(answer, block.timestamp);
    }

    /// The buyer takes $KYZN from the testnet pool for BUY_MULTIPLE times its WETH reserve in ETH.
    function _buyKyzn() internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 wethReserve = pair.token0() == weth ? r0 : r1;
        uint256 ethIn = wethReserve * BUY_MULTIPLE;
        vm.deal(whale, ethIn);
        vm.prank(whale);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            0, _path(weth, address(kyzn)), whale, block.timestamp
        );
        console2.log("pool WETH reserve (1e18)  ", wethReserve);
        console2.log("bought with ETH (1e18)    ", ethIn);
        console2.log("$KYZN bought (1e18)       ", kyzn.balanceOf(whale));
    }

    /// Observations every short window until the oracle has a price and its long average spans a
    /// long window.
    function _buildHistory() internal {
        uint256 steps;
        while (true) {
            _advanceTo(block.timestamp + shortWindow);
            ++steps;
            try oracle.price() returns (uint256) {
                break;
            } catch {
                assertLt(steps, 64, "the oracle never had a price");
            }
        }
        (, uint256 longPeriod) = oracle.longTwap();
        assertGe(longPeriod, longWindow, "the long average spans a long window");
    }

    function _openMarkets() internal {
        for (uint256 id; id < MARKETS; ++id) {
            if (!vault.market(id).open) {
                vm.prank(deployer);
                vault.openMarket(id);
            }
            assertTrue(vault.market(id).open);
        }
    }

    /// 00:00 UTC of the first Monday after today whose Monday, Tuesday and Wednesday are regular.
    function _nextMonday() internal view returns (uint256) {
        uint256 day = block.timestamp / 1 days + 1;
        while ((day + 4) % 7 != 1 || !_regular(day) || !_regular(day + 1) || !_regular(day + 2)) {
            ++day;
        }
        return day * 1 days;
    }

    function _regular(uint256 day) internal view returns (bool) {
        return calendar.dayKind(day) == MarketCalendar.DayKind.Regular;
    }

    /// The first closed day in the calendar file after `day`.
    function _nextClosedDay(uint256 day) internal view returns (uint256) {
        // Reads only script/, which foundry.toml's fs_permissions allow.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(CALENDAR_FILE);
        uint256[] memory closed = abi.decode(vm.parseJson(json, ".closed[*].day"), (uint256[]));
        for (uint256 i; i < closed.length; ++i) {
            if (closed[i] > day) return closed[i];
        }
        revert("no closed day after the drill week");
    }

    function _path(address from, address to) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = from;
        p[1] = to;
    }

    // ================================================================ the deployment

    /// Every address from deployments/46630.json, checked against what the contracts say.
    function _load() internal {
        // Reads only deployments/, which foundry.toml's fs_permissions allow.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(DEPLOYMENT);
        deployer = vm.parseJsonAddress(json, ".deployer");
        kyzn = IERC20(vm.parseJsonAddress(json, ".kyznToken"));
        pair = IUniswapV2PairTwap(vm.parseJsonAddress(json, ".kyznWethPair"));
        router = IUniswapV2Router02(vm.parseJsonAddress(json, ".uniswapV2Router02"));
        weth = vm.parseJsonAddress(json, ".weth");
        ethUsd = TestnetFeed(vm.parseJsonAddress(json, ".ethUsdFeed"));
        vault = SiliconVault(vm.parseJsonAddress(json, ".silicon.vault"));
        oracle = KyznUsdOracle(vm.parseJsonAddress(json, ".silicon.oracle"));
        calendar = MarketCalendar(vm.parseJsonAddress(json, ".silicon.calendar"));
        usdg = TestnetUsdg(vm.parseJsonAddress(json, ".silicon.usdg"));
        feeRouter = vm.parseJsonAddress(json, ".silicon.feeRouter");
        for (uint256 i; i < STOCKS; ++i) {
            stock[i] = TestnetFeed(vm.parseJsonAddress(json, string.concat(".silicon.stockFeeds.", tickers[i])));
            assertEq(stock[i].owner(), deployer, "the deployer sets the stand-ins");
        }
        for (uint256 id; id < MARKETS; ++id) {
            string memory path = string.concat(".silicon.markets[", vm.toString(id), "]");
            synth[id] = SiliconSynth(vm.parseJsonAddress(json, string.concat(path, ".synth")));
            feed[id] = StockIndexFeed(vm.parseJsonAddress(json, string.concat(path, ".feed")));
            SiliconVault.Market memory m = vault.market(id);
            assertEq(address(m.synth), address(synth[id]), "the market's synth");
            assertEq(address(m.feed), address(feed[id]), "the market's feed");
            assertEq(m.minDebt, vm.parseUint(vm.parseJsonString(json, string.concat(path, ".minDebt"))));
            assertEq(m.debtCeiling, vm.parseUint(vm.parseJsonString(json, string.concat(path, ".debtCeiling"))));
            assertEq(feed[id].guardian(), deployer, "the deployer is the guardian");
            assertEq(feed[id].owner(), deployer);
        }
        assertEq(vault.marketCount(), MARKETS);
        assertEq(vault.owner(), deployer);
        assertEq(address(vault.oracle()), address(oracle));
        assertEq(address(vault.kyzn()), address(kyzn));
        assertEq(address(vault.usdg()), address(usdg));
        assertEq(vault.feeRouter(), feeRouter);
        assertEq(vault.auctionDuration(), vm.parseJsonUint(json, ".silicon.auctionDuration"));
        assertEq(address(oracle.pair()), address(pair));
        assertEq(oracle.ethUsdFeed(), address(ethUsd));
        assertEq(ethUsd.owner(), deployer);
        assertEq(usdg.owner(), deployer);
        assertEq(router.WETH(), weth);
        shortWindow = oracle.shortWindow();
        longWindow = oracle.longWindow();
        assertEq(shortWindow, vm.parseJsonUint(json, ".silicon.oracleShortWindow"));
        assertEq(longWindow, vm.parseJsonUint(json, ".silicon.oracleLongWindow"));
    }
}
