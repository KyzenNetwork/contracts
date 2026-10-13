// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IUniswapV2Factory} from "../../src/interfaces/IUniswapV2.sol";
import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {SiliconSynth} from "../../src/silicon/SiliconSynth.sol";
import {SiliconFeed} from "../../src/silicon/SiliconFeed.sol";
import {SiliconFeeRouter} from "../../src/silicon/SiliconFeeRouter.sol";
import {KyznUsdOracle} from "../../src/silicon/KyznUsdOracle.sol";
import {ISiliconSynth} from "../../src/silicon/interfaces/ISiliconSynth.sol";
import {ISiliconFeed} from "../../src/silicon/interfaces/ISiliconFeed.sol";
import {IKyznUsdOracle} from "../../src/silicon/interfaces/IKyznUsdOracle.sol";
import {IUniswapV2PairTwap} from "../../src/silicon/interfaces/IUniswapV2PairTwap.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockFeed} from "../mocks/MockFeed.sol";
import {MockToken, MockSwapTarget, EthSink} from "./mocks/SiliconMocks.sol";

interface IIntegrationPair is IUniswapV2PairTwap {
    function mint(address to) external returns (uint256 liquidity);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// The whole Silicon stack with no stand-in on the price path: SiliconFeed with its dispute
/// window, KyznUsdOracle on the official Uniswap v2 pair (external/uniswap-v2, offline), the vault
/// and the fee router. Pool: 1,000,000 $KYZN and 100 WETH, ETH $2,500, so $KYZN is $0.25.
/// H100-HR at $2.00. Test levels: window 30 minutes, max age 2 hours; the oracle's mainnet
/// averages, 1 hour and 24 hours.
contract SiliconIntegrationTest is Test {
    uint256 internal constant WINDOW = 30 minutes;
    uint256 internal constant SHORT = 1 hours;
    uint256 internal constant LONG = 24 hours;
    bytes32 internal constant SOURCES = keccak256("h100 sources");

    MockWETH internal weth;
    MockFeed internal ethUsd;
    MockToken internal kyzn;
    MockToken internal usdg;
    IIntegrationPair internal pair;
    KyznUsdOracle internal oracle;
    SiliconFeed internal feed;
    SiliconSynth internal synth;
    SiliconVault internal vault;
    SiliconFeeRouter internal router;
    EthSink internal reserveSink;
    EthSink internal stakingSink;
    uint256 internal id;

    address internal reporter = makeAddr("reporter");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    address internal bidder = makeAddr("bidder");
    address internal attacker = makeAddr("attacker");

    function setUp() public {
        vm.warp(1_790_604_000);
        weth = new MockWETH();
        ethUsd = new MockFeed(8, 2_500e8);
        IUniswapV2Factory factory =
            IUniswapV2Factory(deployCode("external/uniswap-v2/UniswapV2Factory.json", abi.encode(address(this))));
        kyzn = new MockToken("KYZN", 18);
        usdg = new MockToken("USDG", 6);
        pair = IIntegrationPair(factory.createPair(address(kyzn), address(weth)));
        kyzn.mint(address(pair), 1_000_000e18);
        weth.deposit{value: 100 ether}();
        assertTrue(weth.transfer(address(pair), 100 ether));
        pair.mint(address(this));

        oracle = new KyznUsdOracle(pair, address(kyzn), address(ethUsd), SHORT, LONG);
        feed = new SiliconFeed("H100-HR / USD", WINDOW, 2 hours);
        feed.setReporter(reporter);
        feed.setGuardian(guardian);
        feed.setMethodology("https://kyzen.network/docs/silicon/h100-hr", keccak256("methodology"));

        vault = new SiliconVault(IERC20(address(kyzn)), IERC20(address(usdg)), IKyznUsdOracle(address(oracle)));
        synth = new SiliconSynth("Kyzen Network H100-HR", "kH100", address(vault));
        id = vault.addMarket(ISiliconSynth(address(synth)), ISiliconFeed(address(feed)));

        router = new SiliconFeeRouter(IWETH(address(weth)));
        reserveSink = new EthSink();
        stakingSink = new EthSink();
        router.setReserve(address(reserveSink));
        router.setStaking(address(stakingSink));
        router.setSplit(5_000);
        router.setKeeper(address(this));

        vault.setMintFee(id, 50);
        vault.setBorrowFee(id, 500);
        vault.setLiquidationPenalty(id, 1_000);
        vault.setDebtCeiling(id, 1_000_000e18);
        vault.setMinDebt(id, 1); // 1 wei of synth: the flows below owe as little as 50 kH100
        vault.setAuctionDuration(6 hours);
        vault.setAuctionStartPremium(2_000);
        vault.setAuctionFloor(4_000);
        vault.setFeeRouter(address(router));
        vault.openMarket(id);

        _report(2e18);
        _tick(WINDOW); // the first price is final
        _run(LONG / 1 hours); // a day of hourly observations: the long average is ready

        address[3] memory users = [alice, bidder, attacker];
        for (uint256 i; i < 3; ++i) {
            kyzn.mint(users[i], 10_000_000e18);
            usdg.mint(users[i], 1_000_000e6);
            vm.startPrank(users[i]);
            kyzn.approve(address(vault), type(uint256).max);
            usdg.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------- helpers

    function _report(uint256 price) internal {
        vm.prank(reporter);
        feed.report(price, SOURCES);
    }

    /// Time passes: ETH/USD is re-stamped and the oracle's observation recorded if due.
    function _tick(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        ethUsd.set(2_500e8, block.timestamp);
        oracle.update();
    }

    /// Hourly operation for `hours_` hours: a report each hour (final 30 minutes later).
    function _run(uint256 hours_) internal {
        for (uint256 i; i < hours_; ++i) {
            (uint256 price,) = feed.latestPrice();
            _report(price);
            _tick(WINDOW);
            _tick(WINDOW);
        }
    }

    function _sellKyzn(uint256 kyznIn) internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool kyznIs0 = pair.token0() == address(kyzn);
        (uint256 k, uint256 w) = kyznIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 out = kyznIn * 997 * w / (k * 1000 + kyznIn * 997);
        kyzn.mint(address(pair), kyznIn);
        if (kyznIs0) pair.swap(0, out, address(this), "");
        else pair.swap(out, 0, address(this), "");
    }

    function _buyKyzn(uint256 wethIn) internal {
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool kyznIs0 = pair.token0() == address(kyzn);
        (uint256 k, uint256 w) = kyznIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 out = wethIn * 997 * k / (w * 1000 + wethIn * 997);
        weth.deposit{value: wethIn}();
        assertTrue(weth.transfer(address(pair), wethIn));
        if (kyznIs0) pair.swap(out, 0, address(this), "");
        else pair.swap(0, out, address(this), "");
    }

    // ---------------------------------------------------------------- flows

    /// Mint, a $KYZN crash in the pool, the TWAP catching up, an auction, bids, fees out as ETH.
    function test_mint_crash_auction_and_fees_out() public {
        // Alice: 4,000 $KYZN ($1,000) and 300 USDG; mints 300 kH100 ($600 + fee).
        vm.startPrank(alice);
        vault.deposit(id, 4_000e18, 300e6);
        vault.mint(id, 300e18);
        vm.stopPrank();
        (,, uint256 ratioBps,) = vault.health(id, alice);
        assertApproxEqAbs(ratioBps, 21_558, 5);

        // The bidder holds synth from a large position of its own.
        vm.startPrank(bidder);
        vault.deposit(id, 1_000_000e18, 0);
        vault.mint(id, 1_000e18);
        vm.stopPrank();

        // $KYZN halves in the pool; the vault still sees the old average until it has aged out.
        _sellKyzn(415_000e18);
        assertGt(oracle.price(), 0.24e18, "same block: unchanged");
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NotLiquidatable.selector, 21_558, 15_000));
        vault.startAuction(alice, id);

        _run(2);
        assertApproxEqRel(oracle.price(), 0.125e18, 0.01e18);
        (,, ratioBps,) = vault.health(id, alice);
        assertLt(ratioBps, 15_000);

        vm.prank(bidder);
        uint256 auctionId = vault.startAuction(alice, id);
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertEq(a.kyzn, 4_000e18);
        assertEq(a.usdg, 300e6);

        // Two bids an hour apart; the second covers what is owed, the rest returns to Alice.
        _tick(1 hours);
        vm.prank(bidder);
        vault.bid(auctionId, 100e18);
        _tick(1 hours);
        vm.prank(bidder);
        vault.bid(auctionId, type(uint256).max);
        assertEq(vault.auction(auctionId).account, address(0));
        (uint256 backK, uint256 backU,) = vault.positions(id, alice);
        assertGt(backK + backU, 0, "leftover collateral returned");
        SiliconVault.Market memory m = vault.market(id);
        assertEq(m.badDebt, 0);
        assertEq(synth.totalSupply(), m.totalDebt + m.auctionDebt + m.badDebt);

        // The router holds the mint fees, borrow fee and penalty as synth; it converts and pays out.
        vault.drip(id);
        uint256 fees = synth.balanceOf(address(router));
        assertGt(fees, 0);
        MockSwapTarget venue = new MockSwapTarget(IWETH(address(weth)));
        vm.deal(address(venue), 10 ether);
        router.queueTarget(address(venue), true);
        _tick(24 hours);
        router.convert(
            address(synth),
            address(venue),
            abi.encodeCall(MockSwapTarget.swap, (IERC20(address(synth)), fees, 0.5 ether, true)),
            fees,
            0.5 ether
        );
        router.distribute();
        assertEq(reserveSink.received(), 0.25 ether);
        assertEq(stakingSink.received(), 0.25 ether);
    }

    /// TWAP manipulation: pumping the pool 100x and minting in the same block mints against
    /// the average, not the pump.
    function test_pump_and_mint_in_one_block_fails() public {
        vm.prank(attacker);
        vault.deposit(id, 10_000e18, 0); // $2,500 at the average
        uint256 before = oracle.price();
        _buyKyzn(900 ether); // spot about 100x
        assertEq(oracle.price(), before);

        // At the pumped spot 10,000 $KYZN would back over 8,000 kH100; at the average, about 828.
        uint256 ratioAtAverage = 10_000 * before * 10_000 / 16_080e18; // 8,040 kH100 x $2.00 of debt
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, ratioAtAverage, 15_000));
        vault.mint(id, 8_000e18);
        vm.prank(attacker);
        vault.mint(id, 820e18);
    }

    /// A pump held for one second moves the average by that second's share only.
    function test_pump_held_one_second_barely_moves_the_limit() public {
        _tick(10 minutes);
        uint256 before = oracle.price();
        _buyKyzn(900 ether);
        vm.warp(block.timestamp + 1);
        ethUsd.set(2_500e8, block.timestamp);
        assertLt(oracle.price(), before * 106 / 100);
    }

    /// A bad print rejected by the guardian never reaches the vault; one left alone does, after
    /// its window.
    function test_guardian_rejection_protects_positions() public {
        vm.startPrank(alice);
        vault.deposit(id, 4_000e18, 0);
        vault.mint(id, 300e18);
        vm.stopPrank();

        _tick(WINDOW);
        _report(20e18); // a bad print: 10x
        _tick(10 minutes);
        vm.prank(guardian);
        feed.reject();
        _report(2e18); // the reporter posts the right price again
        _tick(WINDOW);
        (uint256 price,) = feed.latestPrice();
        assertEq(price, 2e18);
        (,, uint256 ratioBps,) = vault.health(id, alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NotLiquidatable.selector, ratioBps, 15_000));
        vault.startAuction(alice, id);

        _report(20e18);
        _tick(WINDOW); // not rejected: final now
        vault.startAuction(alice, id);
    }

    /// With no report for longer than the maximum age, mint and withdraw stop; repay and deposit work.
    function test_stale_feed_stops_mints_not_repayments() public {
        vm.startPrank(alice);
        vault.deposit(id, 4_000e18, 0);
        vault.mint(id, 100e18);
        vm.stopPrank();
        for (uint256 i; i < 4; ++i) {
            _tick(WINDOW); // the TWAP keeps its observations; the feed gets no report
        }

        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.mint(id, 1e18);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.withdraw(id, 1e18, 0);
        vault.repay(id, 50e18);
        vault.deposit(id, 1e18, 0);
        vm.stopPrank();
    }

    /// Audit: a posted price is public for its whole dispute window before it applies. A rise
    /// of more than 50% posted for H100-HR ($2.00 to $3.20) must not be borrowable at the old
    /// price: 6,000 $KYZN ($1,500) minting 495 kH100 is 150.7% at $2.00 but 94.2% at $3.20, so
    /// the minter could sell the synth for about $1,584 and leave $1,500 of collateral and bad
    /// debt behind. Mint and withdraw value the synth at the higher of the two prices.
    function test_a_posted_rise_cannot_be_borrowed_at_the_old_price() public {
        _report(3.2e18);
        vm.startPrank(attacker);
        vault.deposit(id, 6_000e18, 0);
        vm.expectPartialRevert(SiliconVault.CollateralRatioTooLow.selector);
        vault.mint(id, 495e18);
        vault.mint(id, 300e18); // 150% at $3.20 still mints
        vm.stopPrank();
    }

    /// Audit: the same for a withdrawal ahead of a posted rise. Alice owes 301.5 kH100 against
    /// 6,000 $KYZN ($1,500). Taking 2,000 $KYZN out leaves 165.8% at $2.00 but 103.6% at $3.20;
    /// 200 leaves 150.3% at $3.20 and goes through.
    function test_a_posted_rise_stops_a_withdrawal_at_the_old_price() public {
        vm.startPrank(alice);
        vault.deposit(id, 6_000e18, 0);
        vault.mint(id, 300e18);
        vm.stopPrank();
        _report(3.2e18);
        vm.startPrank(alice);
        vm.expectPartialRevert(SiliconVault.CollateralRatioTooLow.selector);
        vault.withdraw(id, 2_000e18, 0);
        vault.withdraw(id, 200e18, 0);
        vm.stopPrank();
    }

    /// A pending price never liquidates: until its window passes only the final price counts,
    /// and a pending fall does not loosen a mint.
    function test_a_pending_price_neither_liquidates_nor_loosens() public {
        vm.startPrank(alice);
        vault.deposit(id, 6_000e18, 0);
        vault.mint(id, 495e18); // 150.7% at $2.00
        vm.stopPrank();
        _report(3.2e18);
        (,, uint256 ratioBps,) = vault.health(id, alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NotLiquidatable.selector, ratioBps, 15_000));
        vault.startAuction(alice, id);
        _tick(WINDOW);
        vault.startAuction(alice, id); // final now

        vm.prank(attacker);
        vault.deposit(id, 6_000e18, 0);
        _report(1e18); // a fall, pending: the final $3.20 still governs the mint
        vm.prank(attacker);
        vm.expectPartialRevert(SiliconVault.CollateralRatioTooLow.selector);
        vault.mint(id, 495e18);
    }

    /// Audit: after more than three short windows with no observation the vault cannot price
    /// $KYZN, and its own update() is undone with the call that reverts. A direct update() by
    /// anyone (the worker's job) restores the price one short window later.
    function test_twap_gap_needs_a_direct_update() public {
        vm.startPrank(alice);
        vault.deposit(id, 6_000e18, 0);
        vault.mint(id, 100e18);
        vm.stopPrank();
        (uint256 lastObservation,) = oracle.observation(0);
        uint256 count = oracle.observationCount();

        vm.warp(lastObservation + 3 * SHORT + 1);
        ethUsd.set(2_500e8, block.timestamp);
        _report(2e18);
        vm.warp(block.timestamp + WINDOW);
        ethUsd.set(2_500e8, block.timestamp);
        assertTrue(oracle.due());
        vm.prank(alice);
        vm.expectPartialRevert(KyznUsdOracle.ObservationTooOld.selector);
        vault.mint(id, 1e18);
        (uint256 newest,) = oracle.observation(0);
        assertEq(newest, lastObservation, "the vault's update was undone");
        assertEq(oracle.observationCount(), count);

        assertTrue(oracle.update());
        vm.prank(alice);
        vm.expectPartialRevert(KyznUsdOracle.ObservationTooOld.selector);
        vault.mint(id, 1e18);
        _tick(SHORT);
        vm.prank(alice);
        vault.mint(id, 1e18);
    }

    receive() external payable {}
}
