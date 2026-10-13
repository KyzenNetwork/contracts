// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {SiliconFixture} from "./utils/SiliconFixture.sol";

/// Fuzzed health math and fee accrual, against a reference computed here.
contract SiliconVaultFuzzTest is SiliconFixture {
    function setUp() public override {
        super.setUp();
        vault.setDebtCeiling(id, type(uint128).max);
    }

    /// The vault's health rule, recomputed: collateral x 10,000 >= 15,000 x debt value (debt value
    /// rounded up), and $KYZN value x 10,000 >= 5,000 x collateral value.
    function _healthy(uint256 k, uint256 u, uint256 debt, uint256 kyznPrice, uint256 synthPrice)
        internal
        pure
        returns (bool ratioOk, bool shareOk, uint256 ratioBps, uint256 shareBps)
    {
        uint256 kyznValue = Math.mulDiv(k, kyznPrice, 1e18);
        uint256 collateral = kyznValue + u * 1e12;
        uint256 debtValue = Math.mulDiv(debt, synthPrice, 1e18, Math.Rounding.Ceil);
        ratioOk = collateral * 10_000 >= debtValue * 15_000;
        shareOk = kyznValue * 10_000 >= collateral * 5_000;
        ratioBps = debtValue == 0 ? type(uint256).max : collateral * 10_000 / debtValue;
        shareBps = collateral == 0 ? 0 : kyznValue * 10_000 / collateral;
    }

    /// A mint succeeds exactly when the reference says the position is healthy afterwards, and
    /// otherwise fails with the error naming the rule and the numbers. The synth counts at the
    /// higher of its final price and a price waiting in its dispute window (none in half the runs).
    function testFuzz_mint_succeeds_iff_healthy(
        uint256 k,
        uint256 u,
        uint256 amount,
        uint256 kyznPrice,
        uint256 synthPrice,
        uint256 pendingPrice
    ) public {
        k = bound(k, 1, 1e27);
        u = bound(u, 0, 1e15);
        amount = bound(amount, 1, 1e27);
        kyznPrice = bound(kyznPrice, 1e12, 1e22);
        synthPrice = bound(synthPrice, 1e15, 1e24);
        pendingPrice = pendingPrice % 2 == 0 ? 0 : bound(pendingPrice, 1e15, 1e24);
        kyzn.mint(alice, k);
        usdg.mint(alice, u);
        _deposit(alice, k, u);
        oracle.set(kyznPrice);
        feed.set(synthPrice);
        feed.setPending(pendingPrice);

        uint256 debt = amount + _fee(amount);
        (bool ratioOk, bool shareOk, uint256 ratioBps, uint256 shareBps) =
            _healthy(k, u, debt, kyznPrice, Math.max(synthPrice, pendingPrice));
        vm.prank(alice);
        try vault.mint(id, amount) {
            assertTrue(ratioOk && shareOk, "minted while unhealthy");
            assertEq(vault.debtOf(id, alice), debt);
            assertEq(synth.balanceOf(alice), amount);
            _assertSupplyIsDebt();
        } catch (bytes memory reason) {
            if (!ratioOk) {
                assertEq(reason, abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, ratioBps, 15_000));
            } else {
                assertFalse(shareOk, "refused while healthy");
                assertEq(reason, abi.encodeWithSelector(SiliconVault.KyznShareTooLow.selector, shareBps, 5_000));
            }
        }
    }

    /// Whatever the prices do, a withdrawal that succeeds leaves a position with debt at or above
    /// 150% and at least 50% $KYZN.
    function testFuzz_withdraw_never_leaves_a_position_unhealthy(
        uint256 k,
        uint256 u,
        uint256 mintBps,
        uint256 kyznMove,
        uint256 kOut,
        uint256 uOut
    ) public {
        k = bound(k, 1e18, 1e26);
        u = bound(u, 0, k / 1e12); // $KYZN at least half at $1.00
        kyzn.mint(alice, k);
        usdg.mint(alice, u);
        _deposit(alice, k, u);
        // Up to the most the ratio allows at $1.00 and $2.00: collateral / (1.5 x $2 x 1.005).
        uint256 amount = (k + u * 1e12) * bound(mintBps, 1, 10_000) / 10_000 * 1_000 / 3_016;
        _mint(alice, amount);

        oracle.set(bound(kyznMove, 0.2e18, 5e18));
        (uint256 heldK, uint256 heldU,) = _position(alice);
        kOut = bound(kOut, 0, heldK);
        uOut = bound(uOut, 0, heldU);
        if (kOut == 0 && uOut == 0) return;
        vm.prank(alice);
        try vault.withdraw(id, kOut, uOut) {
            (,, uint256 ratioBps, uint256 shareBps) = vault.health(id, alice);
            assertGe(ratioBps, 15_000);
            assertGe(shareBps, 5_000);
        } catch {}
    }

    /// The borrow fee minted on a drip is the debt x rate x seconds / (10,000 x 365 days), rounded
    /// down, and supply stays equal to debt.
    function testFuzz_borrow_fee_matches_the_formula(uint256 amount, uint256 rateBps, uint256 dt) public {
        amount = bound(amount, 1, 1_000_000e18);
        rateBps = bound(rateBps, 0, 10_000);
        dt = bound(dt, 1, 10 * 365 days);
        vault.setMintFee(id, 0);
        // Queued on the open market, applied a day later, before any debt.
        vault.setBorrowFee(id, rateBps);
        _applyQueued(vault.SETTING_BORROW_FEE(), id);
        kyzn.mint(alice, amount * 4);
        _deposit(alice, amount * 4, 0);
        _mint(alice, amount);

        vm.warp(block.timestamp + dt);
        uint256 expected = Math.mulDiv(amount, rateBps * dt, 10_000 * 365 days);
        assertEq(vault.debtOf(id, alice), amount + expected, "view");
        vault.drip(id);
        assertEq(synth.balanceOf(feeRouter), expected);
        assertEq(_market().totalDebt, amount + expected);
        assertEq(vault.debtOf(id, alice), amount + expected);
        _assertSupplyIsDebt();
    }

    /// Fees only grow: dripping in two steps never yields less than one drip over the same time
    /// (the second step charges fee on the first's fee), and never more than that compounding.
    function testFuzz_fees_accrue_monotonically(uint256 amount, uint256 dt1, uint256 dt2) public {
        amount = bound(amount, 1e6, 1_000_000e18);
        dt1 = bound(dt1, 1, 5 * 365 days);
        dt2 = bound(dt2, 1, 5 * 365 days);
        kyzn.mint(alice, amount * 4);
        _deposit(alice, amount * 4, 0);
        _mint(alice, amount);
        uint256 start = _market().totalDebt;

        uint256 snapshot = vm.snapshotState();
        vm.warp(block.timestamp + dt1 + dt2);
        vault.drip(id);
        uint256 once = _market().totalDebt;

        vm.revertToState(snapshot);
        vm.warp(block.timestamp + dt1);
        vault.drip(id);
        uint256 middle = _market().totalDebt;
        uint256 routerMiddle = synth.balanceOf(feeRouter);
        vm.warp(block.timestamp + dt2);
        vault.drip(id);
        uint256 twice = _market().totalDebt;

        assertGe(middle, start);
        assertGe(twice, middle);
        assertGe(synth.balanceOf(feeRouter), routerMiddle);
        assertGe(twice + 1, once, "two drips never charge less than one");
        // The extra is the fee on the first step's fee: start x r1 x r2.
        uint256 r1 = Math.mulDiv(start, 500 * dt1, 10_000 * 365 days);
        uint256 extra = Math.mulDiv(r1, 500 * dt2, 10_000 * 365 days);
        assertLe(twice, once + extra + 1);
        _assertSupplyIsDebt();
    }

    /// A part repayment never lowers the payer's debt by more than it paid, nor raises another
    /// position's debt by more than a wei.
    function testFuzz_part_repayment_rounds_against_the_payer(uint256 a, uint256 b, uint256 pay, uint256 dt) public {
        a = bound(a, 1, 100_000e18);
        b = bound(b, 1, 100_000e18);
        dt = bound(dt, 0, 3 * 365 days);
        kyzn.mint(alice, a * 4 + 1e18);
        kyzn.mint(bob, b * 4 + 1e18);
        _deposit(alice, a * 4 + 1e18, 0);
        _deposit(bob, b * 4 + 1e18, 0);
        _mint(alice, a);
        _warp(dt);
        _mint(bob, b);
        _warp(dt / 2);
        vault.drip(id);

        uint256 aliceDebt = vault.debtOf(id, alice);
        uint256 bobDebt = vault.debtOf(id, bob);
        pay = bound(pay, 1, Math.min(aliceDebt, synth.balanceOf(alice)));
        uint256 repaid = _repay(alice, pay);
        assertEq(repaid, Math.min(pay, aliceDebt));
        assertGe(vault.debtOf(id, alice) + repaid, aliceDebt);
        assertLe(vault.debtOf(id, bob), bobDebt + 1);
        _assertSupplyIsDebt();
    }

    /// Partial bids at random times never pay out more collateral than the auction holds, and
    /// every unit ends with a bidder, back in the position, or at the fee router.
    function testFuzz_auction_pays_out_at_most_the_collateral(uint256 seed, uint256 usdgShare) public {
        uint256 u = bound(usdgShare, 0, 150) * USDG_UNIT;
        uint256 auctionId = _auctionFor(u, seed);
        uint256 vaultK = kyzn.balanceOf(address(vault));
        uint256 vaultU = usdg.balanceOf(address(vault));
        (uint256 paidK, uint256 paidU) = _bidRandomly(auctionId, seed);
        if (vault.auction(auctionId).account != address(0)) {
            // Unsold, it restarts at the first end and closes at the second.
            vm.warp(vault.auction(auctionId).startedAt + AUCTION_DURATION);
            vault.closeAuction(auctionId);
            if (vault.auction(auctionId).account != address(0)) {
                assertTrue(vault.auction(auctionId).restarted);
                vm.warp(vault.auction(auctionId).startedAt + AUCTION_DURATION);
                vault.closeAuction(auctionId);
            }
            assertEq(vault.auction(auctionId).account, address(0), "closed by the second end");
        }
        assertLe(paidK, 300e18);
        assertLe(paidU, u);
        (uint256 backK, uint256 backU,) = _position(alice);
        assertEq(paidK + backK + kyzn.balanceOf(feeRouter), 300e18, "every $KYZN accounted for");
        assertEq(paidU + backU + usdg.balanceOf(feeRouter), u, "every USDG accounted for");
        assertEq(vaultK - kyzn.balanceOf(address(vault)), paidK + kyzn.balanceOf(feeRouter));
        assertEq(vaultU - usdg.balanceOf(address(vault)), paidU + usdg.balanceOf(feeRouter));
        _assertSupplyIsDebt();
    }

    /// Alice: 300 $KYZN and `u` USDG, 99 minted (debt $198.99); $KYZN then falls below 150%,
    /// to between half of that price and it; Bob starts the auction.
    function _auctionFor(uint256 u, uint256 seed) internal returns (uint256 auctionId) {
        _deposit(alice, 300e18, u);
        _mint(alice, 99e18);
        _deposit(bidder, 100_000e18, 0);
        _mint(bidder, 10_000e18);
        // 300 x price + USDG must be under $298.485.
        oracle.set((298e18 - u * 1e12) / 300 * (50 + seed % 50) / 100);
        vm.prank(bob);
        auctionId = vault.startAuction(alice, id);
    }

    /// Up to six bids of random size at random times.
    function _bidRandomly(uint256 auctionId, uint256 seed) internal returns (uint256 paidK, uint256 paidU) {
        for (uint256 i; i < 6; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            if (vault.auction(auctionId).account == address(0)) break;
            vm.warp(block.timestamp + seed % 1 hours);
            if (vault.auctionPrice(auctionId) == 0) break;
            vm.prank(bidder);
            (, uint256 k, uint256 uOut) = vault.bid(auctionId, 1 + (seed >> 128) % 60e18);
            paidK += k;
            paidU += uOut;
        }
    }

    /// The lot's price at any second is its floor plus the start-to-floor spread times the time
    /// left over the duration, rounded up: from the fixture's prices, 54 + 108 x left / duration
    /// (in synth, for 300 $KYZN at $0.90 with the synth at $2.00).
    function testFuzz_lot_price_is_linear(uint256 elapsed) public {
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
        oracle.set(0.9e18);
        vm.prank(bob);
        uint256 auctionId = vault.startAuction(alice, id);
        elapsed = bound(elapsed, 0, AUCTION_DURATION + 1 days);
        vm.warp(block.timestamp + elapsed);
        uint256 expected = elapsed >= AUCTION_DURATION
            ? 0
            : 54e18 + Math.mulDiv(108e18, AUCTION_DURATION - elapsed, AUCTION_DURATION, Math.Rounding.Ceil);
        assertEq(vault.auctionPrice(auctionId), expected);
    }

    /// At any second while an auction runs the lot's price is between its floor and its start
    /// price, with the floor and start worked here from the fixture's prices.
    function testFuzz_lot_price_stays_between_floor_and_start(uint256 elapsed) public {
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
        oracle.set(0.9e18);
        vm.prank(bob);
        uint256 auctionId = vault.startAuction(alice, id);
        uint256 value = Math.mulDiv(300e18, oracle.usdPerKyzn(), feed.price());
        uint256 start = value * (10_000 + START_PREMIUM_BPS) / 10_000;
        uint256 floor = value * AUCTION_FLOOR_BPS / 10_000;
        elapsed = bound(elapsed, 0, AUCTION_DURATION - 1);
        vm.warp(block.timestamp + elapsed);
        uint256 price = vault.auctionPrice(auctionId);
        assertGe(price, floor);
        assertLe(price, start);
        if (elapsed == 0) assertEq(price, start);
    }

    /// Whatever the levels and prices, the lot's price runs from its start sum to its floor sum
    /// (each rounded up over the collateral held, USDG included), never leaves them, and never
    /// rises as time passes.
    function testFuzz_lot_price_between_floor_and_start_for_any_levels(
        uint256 premium,
        uint256 floorBps,
        uint256 kyznPrice,
        uint256 synthPrice,
        uint256 usdgUnits,
        uint256 t1,
        uint256 t2
    ) public {
        premium = bound(premium, 0, 10_000);
        floorBps = bound(floorBps, 1, 9_999);
        kyznPrice = bound(kyznPrice, 0.1e18, 2e18);
        synthPrice = bound(synthPrice, 1e18, 3e18);
        usdgUnits = bound(usdgUnits, 0, 150) * USDG_UNIT;
        vault.setAuctionStartPremium(premium); // queued on the open market: applied a day later
        vault.setAuctionFloor(floorBps);
        _warp(vault.SETTING_DELAY());
        vault.applySetting(vault.SETTING_AUCTION_START_PREMIUM(), 0);
        vault.applySetting(vault.SETTING_AUCTION_FLOOR(), 0);

        _deposit(alice, 300e18, usdgUnits);
        _mint(alice, 99e18);
        oracle.set(0.1e18); // $30 of $KYZN and at most $150 of USDG against $198.99 of debt
        vm.prank(bob);
        uint256 auctionId = vault.startAuction(alice, id);
        // Unsold at the first end, it restarts at the fuzzed prices.
        vm.warp(block.timestamp + AUCTION_DURATION);
        oracle.set(kyznPrice);
        feed.set(synthPrice);
        vault.closeAuction(auctionId);
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertTrue(a.restarted);

        uint256 kyznStart = Math.mulDiv(kyznPrice, (10_000 + premium) * 1e18, synthPrice * 10_000);
        uint256 usdgStart = Math.mulDiv(1e12 * 1e18, (10_000 + premium) * 1e18, synthPrice * 10_000);
        uint256 kyznFloor = Math.mulDiv(kyznPrice, floorBps * 1e18, synthPrice * 10_000);
        uint256 usdgFloor = Math.mulDiv(1e12 * 1e18, floorBps * 1e18, synthPrice * 10_000);
        assertEq(a.kyznStartPrice, kyznStart);
        assertEq(a.usdgStartPrice, usdgStart);
        assertEq(a.kyznFloorPrice, kyznFloor);
        assertEq(a.usdgFloorPrice, usdgFloor);
        uint256 start = Math.mulDiv(a.kyzn, kyznStart, 1e18, Math.Rounding.Ceil)
            + Math.mulDiv(a.usdg, usdgStart, 1e18, Math.Rounding.Ceil);
        uint256 floor = Math.mulDiv(a.kyzn, kyznFloor, 1e18, Math.Rounding.Ceil)
            + Math.mulDiv(a.usdg, usdgFloor, 1e18, Math.Rounding.Ceil);
        assertLe(floor, start);

        t1 = bound(t1, 0, AUCTION_DURATION - 1);
        t2 = bound(t2, t1, AUCTION_DURATION - 1);
        assertEq(vault.auctionPrice(auctionId), start, "starts at the start sum");
        vm.warp(a.startedAt + t1);
        uint256 p1 = vault.auctionPrice(auctionId);
        vm.warp(a.startedAt + t2);
        uint256 p2 = vault.auctionPrice(auctionId);
        assertGe(p1, floor);
        assertLe(p1, start);
        assertGe(p2, floor);
        assertLe(p2, p1, "never rises");
    }

    /// The restart prices from whatever the oracle and the feed say at the end, by the same
    /// formula as the start, and keeps the collateral, debt and penalty.
    function testFuzz_restart_prices_from_the_fresh_prices(uint256 kyznPrice, uint256 synthPrice) public {
        kyznPrice = bound(kyznPrice, 1e12, 1e22);
        synthPrice = bound(synthPrice, 1e15, 1e24);
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
        oracle.set(0.9e18);
        vm.prank(bob);
        uint256 auctionId = vault.startAuction(alice, id);
        SiliconVault.Auction memory first = vault.auction(auctionId);

        vm.warp(first.startedAt + first.duration);
        oracle.set(kyznPrice);
        feed.set(synthPrice);
        vault.closeAuction(auctionId);

        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertTrue(a.restarted);
        assertEq(a.kyznStartPrice, Math.mulDiv(kyznPrice, (10_000 + START_PREMIUM_BPS) * 1e18, synthPrice * 10_000));
        assertEq(a.kyznFloorPrice, Math.mulDiv(kyznPrice, AUCTION_FLOOR_BPS * 1e18, synthPrice * 10_000));
        assertLe(a.kyznFloorPrice, a.kyznStartPrice);
        assertEq(a.startedAt, block.timestamp);
        assertEq(a.duration, AUCTION_DURATION);
        assertEq(a.kyzn, first.kyzn);
        assertEq(a.usdg, first.usdg);
        assertEq(a.debt, first.debt);
        assertEq(a.penalty, first.penalty);
        assertEq(a.account, alice);
        _assertSupplyIsDebt();
    }
}
