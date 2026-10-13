// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Vm} from "forge-std/Vm.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {MockKyznOracle} from "./mocks/SiliconMocks.sol";
import {SiliconFixture} from "./utils/SiliconFixture.sol";

/// Dutch-auction liquidation (SPEC 3.5): price drops, partial and full bids, one restart, bad
/// debt, leftover collateral returned. Test levels: penalty 10%, start premium 20%, floor 40%,
/// duration 6 hours.
///
/// Alice holds 300 $KYZN and owes 99.495 synth (99 minted plus the 0.5% fee): 150.8% at $KYZN
/// $1.00 and the synth $2.00. When $KYZN falls to $0.90 she is at 135.7%. Her auction then owes
/// 99.495 + 9.9495 penalty = 109.4445 synth. Her 300 $KYZN are worth 135 synth ($0.90 x 300 / $2.00)
/// and start at 0.54 synth each ($0.90 x 1.2 / $2.00): 162 synth for the lot, falling to the floor
/// of 0.18 synth each ($0.90 x 0.4 / $2.00), 54 synth for the lot, over 6 hours: 144 after 1 hour
/// (54 + 108 x 5/6), 108 after 3. An auction that ends unsold with debt left restarts once at
/// fresh prices; after the restart's end the debt left is bad debt.
contract SiliconVaultLiquidationTest is SiliconFixture {
    uint256 internal constant DEBT = 99.495e18;
    uint256 internal constant PENALTY = 9.9495e18;
    uint256 internal constant OWED = DEBT + PENALTY;

    function setUp() public override {
        super.setUp();
        _deposit(bidder, 100_000e18, 0);
        _mint(bidder, 10_000e18);
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
    }

    function _start() internal returns (uint256 auctionId) {
        vm.prank(bob);
        auctionId = vault.startAuction(alice, id);
    }

    function _bid(uint256 auctionId, uint256 maxSynth) internal returns (uint256 paid, uint256 k, uint256 u) {
        vm.prank(bidder);
        return vault.bid(auctionId, maxSynth);
    }

    /// The first end restarts the auction, the second closes it with the debt left as bad debt.
    function _expireUnsold(uint256 auctionId) internal {
        SiliconVault.Auction memory a = vault.auction(auctionId);
        vm.warp(a.startedAt + a.duration);
        vault.closeAuction(auctionId);
        a = vault.auction(auctionId);
        assertTrue(a.restarted, "the first end restarts");
        vm.warp(a.startedAt + a.duration);
        vault.closeAuction(auctionId);
    }

    /// The synth value of `kyznAmount` $KYZN at `kyznPrice` USD with the synth at `synthPrice`,
    /// scaled by `bps` / 10,000: how the lot's start (10,000 + premium) and floor prices are built.
    function _lot(uint256 kyznAmount, uint256 kyznPrice, uint256 synthPrice, uint256 bps)
        internal
        pure
        returns (uint256)
    {
        return
            Math.mulDiv(kyznAmount, Math.mulDiv(kyznPrice, bps * 1e18, synthPrice * 10_000), 1e18, Math.Rounding.Ceil);
    }

    // ================================================================ starting an auction

    function test_a_healthy_position_cannot_be_auctioned() public {
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NotLiquidatable.selector, 15_076, 15_000));
        _start();
        vm.prank(bob);
        vm.expectRevert(SiliconVault.NoDebt.selector);
        vault.startAuction(carol, id);
    }

    /// startAuction has the feed record its checked rounds before it reads freshness.
    function test_startAuction_syncs_the_feed_first() public {
        oracle.set(0.9e18);
        uint256 before = feed.syncs();
        assertEq(_start(), 0);
        assertEq(feed.syncs(), before + 1);
    }

    function test_startAuction_needs_fresh_prices() public {
        oracle.set(0.9e18);
        feed.setUpdatedAt(block.timestamp - FEED_MAX_AGE - 1);
        feed.setFreshForLiquidation(false);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.startAuction(alice, id);

        feed.set(SYNTH_USD);
        oracle.setUnavailable(true);
        vm.prank(bob);
        vm.expectRevert(MockKyznOracle.OracleUnavailable.selector);
        vault.startAuction(alice, id);
    }

    /// startAuction asks the feed whether the price is fresh enough to liquidate on, not whether
    /// it is fresh enough to mint on: a feed past its mint window can still back a liquidation.
    function test_startAuction_uses_liquidation_freshness() public {
        oracle.set(0.9e18);
        feed.setUpdatedAt(block.timestamp - FEED_MAX_AGE - 1);
        assertFalse(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());
        assertEq(_start(), 0);
        assertEq(vault.auctionCount(), 1);
    }

    /// And the other way: fresh for minting but not for liquidating is a stale price here.
    function test_startAuction_reverts_when_only_the_mint_price_is_fresh() public {
        oracle.set(0.9e18);
        feed.setFreshForLiquidation(false);
        assertTrue(feed.isFresh());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.startAuction(alice, id);
    }

    function test_price_drop_starts_an_auction() public {
        oracle.set(0.9e18);
        (,, uint256 ratioBps,) = vault.health(id, alice);
        assertEq(ratioBps, 13_568);

        SiliconVault.Market memory before = _market();
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionStarted(0, id, alice, 300e18, 0, DEBT, PENALTY);
        uint256 auctionId = _start();
        assertEq(auctionId, 0);
        assertEq(vault.auctionCount(), 1);

        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertEq(a.account, alice);
        assertEq(a.marketId, id);
        assertEq(a.kyzn, 300e18);
        assertEq(a.usdg, 0);
        assertEq(a.debt, DEBT);
        assertEq(a.penalty, PENALTY);
        assertEq(a.kyznStartPrice, 0.54e18); // 0.9 x 1.2 / 2
        assertEq(a.usdgStartPrice, 0.6e30); // 1e12 x 1e18 x 1.2 / 2
        assertEq(a.kyznFloorPrice, 0.18e18); // 0.9 x 0.4 / 2
        assertEq(a.usdgFloorPrice, 0.2e30); // 1e12 x 1e18 x 0.4 / 2
        assertEq(a.startedAt, block.timestamp);
        assertEq(a.duration, AUCTION_DURATION);
        assertFalse(a.restarted);

        (uint256 k, uint256 u, uint256 shares) = _position(alice);
        assertEq(k + u + shares, 0, "the position is emptied");
        SiliconVault.Market memory m = _market();
        assertEq(m.totalDebt, before.totalDebt - DEBT);
        assertEq(m.totalShares, before.totalShares - DEBT);
        assertEq(m.auctionDebt, DEBT);
        _assertSupplyIsDebt();
        assertEq(kyzn.balanceOf(address(vault)), 100_300e18, "collateral stays in the vault");
    }

    /// The lot's price falls linearly from the start premium to the floor and is zero once the
    /// duration has passed. The expected values are built here from the fixture's own prices
    /// ($KYZN $0.90, the synth $2.00, premium 2,000, floor 4,000) with the vault's formula, and
    /// checked beside literals worked by hand: the lot is worth 300 x $0.90 / $2.00 = 135 synth.
    function test_lotPriceFallsFromStartToFloor() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        uint256 t0 = block.timestamp;

        uint256 value = _lot(300e18, oracle.usdPerKyzn(), feed.price(), 10_000);
        uint256 start = _lot(300e18, oracle.usdPerKyzn(), feed.price(), 10_000 + START_PREMIUM_BPS);
        uint256 floor = _lot(300e18, oracle.usdPerKyzn(), feed.price(), AUCTION_FLOOR_BPS);
        assertEq(start, value * 12 / 10, "start: the oracle value x 1.2");
        assertEq(floor, value * 4 / 10, "floor: the oracle value x 0.4");

        assertEq(vault.auctionPrice(auctionId), start);
        assertEq(vault.auctionPrice(auctionId), 162e18); // 135 x 1.2

        vm.warp(t0 + 1 hours);
        assertEq(vault.auctionPrice(auctionId), 144e18); // 54 + (162 - 54) x 5 / 6 = 54 + 90

        vm.warp(t0 + AUCTION_DURATION / 2);
        assertEq(vault.auctionPrice(auctionId), floor + (start - floor) / 2);
        assertEq(vault.auctionPrice(auctionId), value * 8 / 10, "half way: the oracle value x 0.8");
        assertEq(vault.auctionPrice(auctionId), 108e18); // 54 + 108 x 3 / 6 = 54 + 54

        vm.warp(t0 + 5 hours);
        assertEq(vault.auctionPrice(auctionId), 72e18); // 54 + 108 x 1 / 6 = 54 + 18

        vm.warp(t0 + AUCTION_DURATION - 1);
        assertEq(
            vault.auctionPrice(auctionId), floor + Math.mulDiv(start - floor, 1, AUCTION_DURATION, Math.Rounding.Ceil)
        );
        assertEq(vault.auctionPrice(auctionId), 54.005e18); // 54 + 108 / 21,600 = 54 + 0.005
        assertGt(vault.auctionPrice(auctionId), floor, "one second before the end: just above the floor");

        vm.warp(t0 + AUCTION_DURATION);
        assertEq(vault.auctionPrice(auctionId), 0); // ended: it can only be closed
    }

    /// The price never goes below the floor while the auction runs, and never rises.
    function test_the_price_never_falls_below_the_floor() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        uint256 t0 = block.timestamp;
        uint256 floor = _lot(300e18, 0.9e18, SYNTH_USD, AUCTION_FLOOR_BPS);
        assertEq(floor, 54e18);
        uint256 last = type(uint256).max;
        for (uint256 elapsed; elapsed < AUCTION_DURATION; elapsed += 97) {
            vm.warp(t0 + elapsed);
            uint256 price = vault.auctionPrice(auctionId);
            assertGe(price, floor);
            assertLe(price, last);
            last = price;
        }
    }

    /// Settings that take effect after the start do not touch a running auction. On the open
    /// market they are queued; the auction starts inside their 24 hours and they apply while it
    /// runs.
    function test_running_auction_keeps_its_terms() public {
        vault.setAuctionStartPremium(0);
        vault.setAuctionFloor(100);
        vault.setAuctionDuration(1 hours);
        vault.setLiquidationPenalty(id, 0);
        _warp(1 days - 1 hours);
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + 1 hours);
        vault.applySetting(vault.SETTING_AUCTION_START_PREMIUM(), 0);
        vault.applySetting(vault.SETTING_AUCTION_FLOOR(), 0);
        vault.applySetting(vault.SETTING_AUCTION_DURATION(), 0);
        vault.applySetting(vault.SETTING_LIQUIDATION_PENALTY(), id);
        assertEq(vault.auctionDuration(), 1 hours, "the new settings are in force");
        assertEq(_market().liquidationPenaltyBps, 0);

        oracle.set(0.1e18);
        feed.set(9e18);
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertEq(vault.auctionPrice(auctionId), 144e18, "an hour into its six-hour fall from 162 to 54");
        assertEq(a.penalty, Math.mulDiv(a.debt, PENALTY_BPS, 10_000));
        assertEq(a.kyznStartPrice, 0.54e18);
        assertEq(a.kyznFloorPrice, 0.18e18);
        assertEq(a.duration, AUCTION_DURATION);
        assertEq(a.startPremiumBps, START_PREMIUM_BPS);
        assertEq(a.floorBps, AUCTION_FLOOR_BPS);
        assertEq(a.feeRouter, feeRouter);
    }

    // ================================================================ bids

    /// One hour in (144 synth for the lot): 50 synth buys 50/144 of the $KYZN and burns 50 of debt.
    function test_partial_bid() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + 1 hours);
        uint256 supplyBefore = synth.totalSupply();
        uint256 kyznOut = uint256(300e18) * 50e18 / 144e18;

        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionBid(auctionId, bidder, 50e18, kyznOut, 0);
        (uint256 paid, uint256 k, uint256 u) = _bid(auctionId, 50e18);
        assertEq(paid, 50e18);
        assertEq(k, kyznOut);
        assertEq(u, 0);
        assertEq(kyzn.balanceOf(bidder), 10_000_000e18 - 100_000e18 + kyznOut);

        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertEq(a.debt, DEBT - 50e18);
        assertEq(a.penalty, PENALTY, "debt is repaid before the penalty");
        assertEq(a.kyzn, 300e18 - kyznOut);
        assertEq(synth.totalSupply(), supplyBefore - 50e18);
        assertEq(_market().auctionDebt, DEBT - 50e18);
        _assertSupplyIsDebt();

        // The rest of the lot is priced pro-rata: 144 x (300 - out) / 300 = 144 - 50 = 94.
        assertApproxEqAbs(vault.auctionPrice(auctionId), 94e18, 1);
    }

    /// A bid covering debt and penalty ends the auction: the collateral left returns to Alice.
    function test_full_bid_returns_leftover_collateral() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + 1 hours);
        uint256 routerBefore = synth.balanceOf(feeRouter);
        uint256 kyznOut = uint256(300e18) * OWED / 144e18;
        uint256 leftover = 300e18 - kyznOut;

        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionBid(auctionId, bidder, OWED, kyznOut, 0);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionClosed(auctionId, alice, leftover, 0, 0);
        (uint256 paid,,) = _bid(auctionId, 1_000e18);
        assertEq(paid, OWED, "never more than the auction is owed");
        assertEq(synth.balanceOf(feeRouter) - routerBefore, PENALTY, "the penalty goes to the fee router");

        assertEq(vault.auction(auctionId).account, address(0), "closed");
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionNotActive.selector, auctionId));
        vault.bid(auctionId, 1);

        (uint256 k,, uint256 shares) = _position(alice);
        assertEq(k, leftover);
        assertEq(shares, 0);
        SiliconVault.Market memory m = _market();
        assertEq(m.auctionDebt, 0);
        assertEq(m.badDebt, 0);
        _assertSupplyIsDebt();

        // Alice takes back what was left, with no debt and no price needed.
        oracle.setUnavailable(true);
        uint256 before = kyzn.balanceOf(alice);
        _withdraw(alice, leftover, 0);
        assertEq(kyzn.balanceOf(alice), before + leftover);
    }

    /// $KYZN at $0.50: the lot (300 $KYZN, $150) starts at 90 synth, below the 109.4 owed. A bid
    /// for all of it leaves 9.495 of debt that no collateral covers: bad debt.
    function test_full_bid_below_debt_records_bad_debt() public {
        oracle.set(0.5e18);
        uint256 auctionId = _start();
        assertEq(vault.auctionPrice(auctionId), 90e18);
        uint256 routerBefore = synth.balanceOf(feeRouter);

        vm.expectEmit(address(vault));
        emit SiliconVault.BadDebtRecorded(id, auctionId, DEBT - 90e18);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionClosed(auctionId, feeRouter, 0, 0, DEBT - 90e18);
        (uint256 paid, uint256 k,) = _bid(auctionId, 1_000e18);
        assertEq(paid, 90e18);
        assertEq(k, 300e18);
        assertEq(synth.balanceOf(feeRouter), routerBefore, "no penalty was paid");

        SiliconVault.Market memory m = _market();
        assertEq(m.auctionDebt, 0);
        assertEq(m.badDebt, DEBT - 90e18);
        _assertSupplyIsDebt();
        (uint256 aliceKyzn,,) = _position(alice);
        assertEq(aliceKyzn, 0);
    }

    /// Nobody bids: after the end the auction restarts in place, once, at the prices of the
    /// moment it restarts. The restart is the same auction (id, collateral, debt, penalty, terms)
    /// with a new start and new start and floor prices; it keeps the duration it started with,
    /// though a 3-hour duration has taken effect since. Nothing is closed and no debt is bad.
    function test_unsoldAuctionRestartsOnceAtFreshPrices() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        uint256 endsAt = block.timestamp + AUCTION_DURATION;
        // The owner queues a 3-hour duration now; it takes effect a day later, before the restart,
        // and does not reach this auction.
        vault.setAuctionDuration(3 hours);
        uint256 restartAt = block.timestamp + 1 days;

        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionNotEnded.selector, auctionId, endsAt));
        vault.closeAuction(auctionId);

        vm.warp(endsAt);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionEnded.selector, auctionId));
        vault.bid(auctionId, 1e18);

        // By the restart $KYZN is at $0.80 and the synth at $2.50; the duration in force is 3 hours.
        vm.warp(restartAt);
        vault.applySetting(vault.SETTING_AUCTION_DURATION(), 0);
        oracle.set(0.8e18);
        feed.set(2.5e18);
        uint256 kyznBefore = kyzn.balanceOf(address(vault));
        uint256 updates = oracle.updates();
        uint256 syncs = feed.syncs();
        SiliconVault.Market memory before = _market();

        // 0.8 x 1.2 / 2.5 = 0.384 synth a $KYZN to start, 0.8 x 0.4 / 2.5 = 0.128 at the floor;
        // USDG: 1.2 / 2.5 = 0.48 and 0.4 / 2.5 = 0.16 a whole USDG (1e12 x 1e18 per unit).
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionRestarted(auctionId, 0.384e18, 0.48e30);
        vm.prank(carol); // anyone
        vault.closeAuction(auctionId);

        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertEq(a.account, alice, "the same auction");
        assertEq(a.marketId, id);
        assertEq(vault.auctionCount(), 1, "no new auction");
        assertTrue(a.restarted);
        assertEq(a.startedAt, restartAt, "a new start: now");
        assertEq(vault.auctionDuration(), 3 hours);
        assertEq(a.duration, AUCTION_DURATION, "the duration it started with");
        assertEq(a.kyznStartPrice, 0.384e18);
        assertEq(a.usdgStartPrice, 0.48e30);
        assertEq(a.kyznFloorPrice, 0.128e18);
        assertEq(a.usdgFloorPrice, 0.16e30);
        assertEq(a.kyzn, 300e18, "the collateral stays in the auction");
        assertEq(a.usdg, 0);
        assertEq(a.debt, DEBT, "debt and penalty are unchanged");
        assertEq(a.penalty, PENALTY);
        assertEq(oracle.updates(), updates + 1, "the oracle is updated before it is read");
        assertEq(feed.syncs(), syncs + 1, "the feed syncs before its freshness is read");

        // The same formula as the start, from today's prices: 115.2 synth for the lot, 38.4 at the floor.
        assertEq(a.kyznStartPrice, _lot(1e18, 0.8e18, 2.5e18, 10_000 + START_PREMIUM_BPS));
        assertEq(a.kyznFloorPrice, _lot(1e18, 0.8e18, 2.5e18, AUCTION_FLOOR_BPS));
        assertEq(vault.auctionPrice(auctionId), 115.2e18);
        vm.warp(restartAt + 90 minutes);
        assertEq(vault.auctionPrice(auctionId), 96e18); // 38.4 + (115.2 - 38.4) x 4.5 / 6

        SiliconVault.Market memory m = _market();
        assertEq(m.badDebt, 0, "no bad debt yet");
        assertEq(m.badDebt, before.badDebt);
        assertEq(m.auctionDebt, before.auctionDebt);
        assertEq(m.totalDebt, before.totalDebt);
        assertEq(kyzn.balanceOf(address(vault)), kyznBefore, "the collateral stays in the vault");
        assertEq(kyzn.balanceOf(feeRouter), 0);
        (uint256 k, uint256 u, uint256 shares) = _position(alice);
        assertEq(k + u + shares, 0, "the position stays empty");
        _assertSupplyIsDebt();

        // It is a running auction again: not closable before its new end.
        vm.expectRevert(
            abi.encodeWithSelector(SiliconVault.AuctionNotEnded.selector, auctionId, restartAt + AUCTION_DURATION)
        );
        vault.closeAuction(auctionId);
    }

    /// The restart is silent about nothing else: of the vault's own events, no AuctionClosed and
    /// no BadDebtRecorded (what the oracle and the feed emit when the vault reads them is theirs).
    function test_restart_emits_only_the_restart() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + AUCTION_DURATION);
        vm.recordLogs();
        vault.closeAuction(auctionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 fromVault;
        Vm.Log memory restart;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(vault)) continue;
            ++fromVault;
            restart = logs[i];
        }
        assertEq(fromVault, 1);
        assertEq(restart.topics[0], SiliconVault.AuctionRestarted.selector);
        assertEq(restart.topics[1], bytes32(auctionId));
    }

    /// The second end, with the debt still unpaid: it is bad debt and the collateral left goes to
    /// the fee router, as an auction ended before the restart existed. No price is read.
    function test_secondUnsoldEndRecordsBadDebt() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + AUCTION_DURATION);
        vault.closeAuction(auctionId); // the restart
        uint256 endsAt = vault.auction(auctionId).startedAt + AUCTION_DURATION;

        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionNotEnded.selector, auctionId, endsAt));
        vault.closeAuction(auctionId);
        vm.warp(endsAt);
        vm.prank(bidder);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionEnded.selector, auctionId));
        vault.bid(auctionId, 1e18);

        // No price is needed to give up: the oracle is down and the feed is stale.
        oracle.setUnavailable(true);
        feed.setFreshForLiquidation(false);
        uint256 updates = oracle.updates();

        vm.expectEmit(address(vault));
        emit SiliconVault.BadDebtRecorded(id, auctionId, DEBT);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionClosed(auctionId, feeRouter, 300e18, 0, DEBT);
        vm.prank(carol); // anyone
        vault.closeAuction(auctionId);
        assertEq(oracle.updates(), updates, "no price was read");

        assertEq(kyzn.balanceOf(feeRouter), 300e18);
        SiliconVault.Market memory m = _market();
        assertEq(m.badDebt, DEBT);
        assertEq(m.auctionDebt, 0);
        assertEq(vault.auction(auctionId).account, address(0), "closed");
        _assertSupplyIsDebt();
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionNotActive.selector, auctionId));
        vault.closeAuction(auctionId);
    }

    /// The restart reads the prices a liquidation reads. A feed not fresh for liquidation, or an
    /// oracle with no price, keeps the auction waiting: the call reverts and anyone may retry.
    function test_restartNeedsLiquidationFreshPrices() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        SiliconVault.Auction memory ended = vault.auction(auctionId);
        vm.warp(ended.startedAt + ended.duration);

        feed.setFreshForLiquidation(false);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.closeAuction(auctionId);

        feed.setFreshForLiquidation(true);
        oracle.setUnavailable(true);
        vm.expectRevert(MockKyznOracle.OracleUnavailable.selector);
        vault.closeAuction(auctionId);

        // Nothing moved while it waited.
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertFalse(a.restarted);
        assertEq(a.startedAt, ended.startedAt);
        assertEq(a.kyzn, 300e18);
        assertEq(a.debt, DEBT);
        assertEq(_market().badDebt, 0);

        // And the retry works once prices are back, however long it waited.
        oracle.setUnavailable(false);
        vm.warp(block.timestamp + 2 days);
        feed.set(SYNTH_USD);
        vault.closeAuction(auctionId);
        a = vault.auction(auctionId);
        assertTrue(a.restarted);
        assertEq(a.startedAt, block.timestamp);
    }

    /// Liquidation freshness is the test, not mint freshness: a feed past its mint window can
    /// still back the restart, and one fresh for minting but not for liquidating cannot.
    function test_restart_uses_liquidation_freshness_not_mint_freshness() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + AUCTION_DURATION);
        assertFalse(feed.isFresh(), "past the mint window");
        assertTrue(feed.isFreshForLiquidation());
        vault.closeAuction(auctionId);
        assertTrue(vault.auction(auctionId).restarted);

        uint256 other = _secondAuction();
        vm.warp(vault.auction(other).startedAt + AUCTION_DURATION);
        feed.set(SYNTH_USD);
        feed.setFreshForLiquidation(false);
        assertTrue(feed.isFresh());
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.closeAuction(other);
    }

    /// Bob's position, liquidated at $0.80 while the first auction runs on.
    function _secondAuction() internal returns (uint256 auctionId) {
        feed.set(SYNTH_USD);
        _deposit(bob, 300e18, 0);
        oracle.set(1e18);
        _mint(bob, 99e18);
        oracle.set(0.8e18);
        vm.prank(carol);
        auctionId = vault.startAuction(bob, id);
    }

    /// The restart is a second chance, not a second start: bids before the first end carry over
    /// (the debt, the penalty and the collateral left are the restart's), and the restarted lot
    /// is priced from what is left.
    function test_partial_bids_carry_into_the_restart() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + 1 hours);
        (, uint256 kyznOut,) = _bid(auctionId, 50e18);
        SiliconVault.Auction memory beforeRestart = vault.auction(auctionId);
        assertEq(beforeRestart.debt, DEBT - 50e18);

        vm.warp(beforeRestart.startedAt + beforeRestart.duration);
        vault.closeAuction(auctionId);
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertTrue(a.restarted);
        assertEq(a.debt, DEBT - 50e18);
        assertEq(a.penalty, PENALTY);
        assertEq(a.kyzn, 300e18 - kyznOut);
        assertEq(a.kyznStartPrice, 0.54e18, "prices unchanged: the same oracle and feed");
        // What is left of the lot starts at (300 - out) x 0.54 synth.
        assertEq(vault.auctionPrice(auctionId), _lot(a.kyzn, 0.9e18, SYNTH_USD, 10_000 + START_PREMIUM_BPS));

        // At the restart's end the debt still owed is bad debt: 49.495 of the 99.495.
        vm.warp(a.startedAt + a.duration);
        vault.closeAuction(auctionId);
        assertEq(_market().badDebt, DEBT - 50e18);
        assertEq(kyzn.balanceOf(feeRouter), 300e18 - kyznOut);
        _assertSupplyIsDebt();
    }

    /// A restarted auction ends like any other: a bid at its new price that covers what is owed
    /// closes it, and the collateral left returns to the position.
    function test_a_restarted_auction_can_still_be_repaid() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + AUCTION_DURATION);
        oracle.set(1.2e18); // $KYZN recovered by the end
        feed.set(SYNTH_USD);
        vault.closeAuction(auctionId);

        // 300 x 1.2 / 2 = 180 synth worth, 216 at the start (x 1.2), 72 at the floor (x 0.4);
        // an hour in: 72 + (216 - 72) x 5 / 6 = 192.
        assertEq(vault.auctionPrice(auctionId), 216e18);
        vm.warp(block.timestamp + 1 hours);
        assertEq(vault.auctionPrice(auctionId), 192e18);
        uint256 kyznOut = uint256(300e18) * OWED / 192e18;
        uint256 leftover = 300e18 - kyznOut;

        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionClosed(auctionId, alice, leftover, 0, 0);
        (uint256 paid, uint256 k,) = _bid(auctionId, 1_000e18);
        assertEq(paid, OWED);
        assertEq(k, kyznOut);
        assertEq(vault.auction(auctionId).account, address(0), "closed");
        (uint256 backK,,) = _position(alice);
        assertEq(backK, leftover);
        assertEq(_market().badDebt, 0);
        assertEq(_market().auctionDebt, 0);
        _assertSupplyIsDebt();
    }

    /// A full bid that repays the auction closes it on the spot: the collateral left returns to
    /// the position, with no restart.
    function test_repaidAuctionClosesWithoutRestart() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + 1 hours);
        uint256 leftover = 300e18 - uint256(300e18) * OWED / 144e18;

        vm.recordLogs();
        _bid(auctionId, 1_000e18);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != SiliconVault.AuctionRestarted.selector, "no restart");
        }
        assertEq(vault.auction(auctionId).account, address(0), "closed");
        (uint256 k,,) = _position(alice);
        assertEq(k, leftover, "the collateral left returns to the position");
        assertEq(kyzn.balanceOf(feeRouter), 0);
        assertEq(_market().badDebt, 0);
        vm.warp(block.timestamp + AUCTION_DURATION);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionNotActive.selector, auctionId));
        vault.closeAuction(auctionId);
    }

    /// With the debt repaid and only a penalty owed, the end closes the auction rather than
    /// restarting it, and needs no price: the collateral left returns to the position.
    function test_debt_repaid_penalty_left_ends_without_restart_or_prices() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + 1 hours);
        (, uint256 kyznOut,) = _bid(auctionId, DEBT); // exactly the debt: the penalty is left
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertEq(a.debt, 0);
        assertEq(a.penalty, PENALTY);

        oracle.setUnavailable(true);
        feed.setFreshForLiquidation(false);
        vm.warp(a.startedAt + a.duration);
        vm.recordLogs();
        vault.closeAuction(auctionId);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1, "AuctionClosed only");
        assertEq(logs[0].topics[0], SiliconVault.AuctionClosed.selector);
        (uint256 k,,) = _position(alice);
        assertEq(k, 300e18 - kyznOut);
        assertEq(_market().badDebt, 0);
    }

    /// Nobody bids, twice: once the restart's duration passes the debt is bad debt and the
    /// collateral goes to the fee router.
    function test_expiry_with_bad_debt() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        _expireUnsold(auctionId);

        assertEq(kyzn.balanceOf(feeRouter), 300e18);
        SiliconVault.Market memory m = _market();
        assertEq(m.badDebt, DEBT);
        assertEq(m.auctionDebt, 0);
        _assertSupplyIsDebt();
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionNotActive.selector, auctionId));
        vault.closeAuction(auctionId);
    }

    /// Partial bids, then the clock runs out: what the bids did not burn is bad debt.
    function test_partial_bids_then_expiry() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + 1 hours);
        _bid(auctionId, 30e18);
        vm.warp(block.timestamp + 1 hours);
        _bid(auctionId, 20e18);
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertEq(a.debt, DEBT - 50e18);

        _expireUnsold(auctionId);
        SiliconVault.Market memory m = _market();
        assertEq(m.badDebt, DEBT - 50e18);
        assertEq(kyzn.balanceOf(feeRouter), a.kyzn);
        _assertSupplyIsDebt();
    }

    /// Bids that cover the debt but not all of the penalty: no bad debt; at the end the
    /// collateral left returns to the position and the penalty left is waived.
    function test_debt_covered_penalty_short() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + 1 hours);
        uint256 routerBefore = synth.balanceOf(feeRouter);
        _bid(auctionId, DEBT + 1e18);
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertEq(a.debt, 0);
        assertEq(a.penalty, PENALTY - 1e18);
        assertEq(synth.balanceOf(feeRouter) - routerBefore, 1e18);
        assertEq(_market().auctionDebt, 0);

        vm.warp(a.startedAt + a.duration);
        vm.recordLogs();
        vault.closeAuction(auctionId);
        assertEq(vm.getRecordedLogs().length, 1, "AuctionClosed only: no transfer, no BadDebtRecorded");
        assertEq(_market().badDebt, 0);
        assertEq(kyzn.balanceOf(feeRouter), 0);
        (uint256 k,,) = _position(alice);
        assertEq(k, a.kyzn);
        _assertSupplyIsDebt();
    }

    /// Audit: a last bid one wei short of the penalty must not cost Alice the rest of her
    /// collateral. One hour in (144 synth for the lot), a bid of 109.4445 synth less one wei
    /// takes 228.0 of her 300 $KYZN; no one will bid one wei for the rest. Once the debt is
    /// repaid, what is left at the end is hers: 72.0 $KYZN, about $65, against a one-wei penalty.
    function test_dust_penalty_left_keeps_the_leftover_with_the_owner() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.warp(block.timestamp + 1 hours);
        (, uint256 kyznOut,) = _bid(auctionId, OWED - 1);
        uint256 leftover = 300e18 - kyznOut;
        assertEq(vault.auction(auctionId).debt, 0);
        assertEq(vault.auction(auctionId).penalty, 1);

        vm.warp(vault.auction(auctionId).startedAt + AUCTION_DURATION);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionClosed(auctionId, alice, leftover, 0, 0);
        vault.closeAuction(auctionId);

        (uint256 k,,) = _position(alice);
        assertEq(k, leftover, "the leftover returns to the position");
        assertEq(kyzn.balanceOf(feeRouter), 0, "the fee router takes no collateral");
        assertEq(_market().badDebt, 0);
        _assertSupplyIsDebt();
    }

    /// A lot with USDG: both tokens go pro-rata, USDG priced at $1.00 plus the premium.
    function test_mixed_collateral_lot() public {
        _deposit(carol, 200e18, 100 * USDG_UNIT); // $300
        _mint(carol, 99e18);
        oracle.set(0.8e18); // 160 + 100 = $260 against $198.99: 130.7%
        vm.prank(bob);
        uint256 auctionId = vault.startAuction(carol, id);
        // 200 x 0.8 x 1.2 / 2 = 96 synth, plus 100 x 1.2 / 2 = 60 synth.
        assertEq(vault.auctionPrice(auctionId), 156e18);
        (uint256 paid, uint256 k, uint256 u) = _bid(auctionId, 39e18); // a quarter
        assertEq(paid, 39e18);
        assertEq(k, 50e18);
        assertEq(u, 25 * USDG_UNIT);
        assertEq(usdg.balanceOf(bidder), 10_000_000 * USDG_UNIT + 25 * USDG_UNIT);
    }

    /// Bids read no price: they work with the feed stale and the oracle down.
    function test_bids_need_no_price() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        feed.setUpdatedAt(block.timestamp - FEED_MAX_AGE - 1);
        oracle.setUnavailable(true);
        vm.warp(block.timestamp + 1 hours);
        (uint256 paid,,) = _bid(auctionId, 10e18);
        assertEq(paid, 10e18);
    }

    function test_bid_rules() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        vm.startPrank(bidder);
        vm.expectRevert(SiliconVault.ZeroAmount.selector);
        vault.bid(auctionId, 0);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionNotActive.selector, 7));
        vault.bid(7, 1e18);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.AuctionNotActive.selector, 7));
        vault.auctionPrice(7);

        vm.prank(carol); // holds no synth
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, carol, 0, 1e18));
        vault.bid(auctionId, 1e18);
    }

    // ================================================================ after an auction

    function test_cover_bad_debt() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        _expireUnsold(auctionId);

        vm.startPrank(bidder);
        vm.expectRevert(SiliconVault.ZeroAmount.selector);
        vault.coverBadDebt(id, 0);
        vm.expectEmit(address(vault));
        emit SiliconVault.BadDebtCovered(id, bidder, 40e18);
        assertEq(vault.coverBadDebt(id, 40e18), 40e18);
        assertEq(vault.coverBadDebt(id, 1_000e18), DEBT - 40e18, "never more than the bad debt");
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NoBadDebt.selector, id));
        vault.coverBadDebt(id, 1);
        vm.stopPrank();
        assertEq(_market().badDebt, 0);
        _assertSupplyIsDebt();
    }

    /// The debt ceiling counts auction debt and bad debt.
    function test_ceiling_counts_auctions_and_bad_debt() public {
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        SiliconVault.Market memory m = _market();
        vault.setDebtCeiling(id, m.totalDebt + m.auctionDebt);
        vm.prank(bidder);
        vm.expectRevert(
            abi.encodeWithSelector(
                SiliconVault.DebtCeilingExceeded.selector, m.totalDebt + m.auctionDebt + 2, m.totalDebt + m.auctionDebt
            )
        );
        vault.mint(id, 1); // 1 wei plus a 1-wei fee

        _expireUnsold(auctionId);
        feed.set(SYNTH_USD);
        m = _market();
        vault.setDebtCeiling(id, m.totalDebt + m.badDebt);
        vm.prank(bidder);
        vm.expectPartialRevert(SiliconVault.DebtCeilingExceeded.selector); // the mint drips 12 hours of fee first
        vault.mint(id, 1);
    }

    /// After a liquidation the account can open a new position in the same market.
    function test_liquidated_account_starts_again() public {
        oracle.set(0.9e18);
        _start();
        oracle.set(1e18);
        _deposit(alice, 300e18, 0);
        _mint(alice, 10e18);
        assertEq(vault.debtOf(id, alice), 10.05e18);
    }

    /// Borrow fee accrued before the auction is part of its debt; the auction's own debt is fixed.
    function test_auction_takes_the_accrued_fee() public {
        _warp(365 days); // 99.495 x 1.05
        oracle.set(0.9e18);
        uint256 auctionId = _start();
        uint256 debt = vault.auction(auctionId).debt;
        assertApproxEqAbs(debt, DEBT * 105 / 100, 1);
        _warp(3 hours);
        vault.drip(id);
        assertEq(vault.auction(auctionId).debt, debt);
        _assertSupplyIsDebt();
    }
}
