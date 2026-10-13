// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Vm} from "forge-std/Vm.sol";
import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {SiliconSynth} from "../../src/silicon/SiliconSynth.sol";
import {ISiliconSynth} from "../../src/silicon/interfaces/ISiliconSynth.sol";
import {ISiliconFeed} from "../../src/silicon/interfaces/ISiliconFeed.sol";
import {IKyznUsdOracle} from "../../src/silicon/interfaces/IKyznUsdOracle.sol";
import {MockSiliconFeed} from "./mocks/SiliconMocks.sol";
import {SiliconFixture} from "./utils/SiliconFixture.sol";

/// SiliconVault: the settings that act on open positions wait 24 hours once they can touch one
/// (final review I1), a market's feed can be replaced on the same notice (I2), and a zero synth
/// price stops every priced action (M1).
///
/// The fixture's market 0 is open, so its own risk settings and every vault-wide one queue. A
/// market added here and not opened takes its settings at once, as does a vault with no market
/// open. Test levels: borrow fee 5% a year, penalty 10%, auction 6 hours, premium 20%, floor 40%.
contract SiliconVaultSettingsTest is SiliconFixture {
    uint16 internal constant BORROW = 2;
    uint16 internal constant PENALTY = 4;
    uint16 internal constant DURATION = 16;
    uint16 internal constant PREMIUM = 32;
    uint16 internal constant ROUTER = 64;
    uint16 internal constant FEED = 128;
    uint16 internal constant FLOOR = 256;
    uint256 internal constant DELAY = 24 hours;

    address internal guardian = makeAddr("guardian");

    function _freshMarket() internal returns (uint256 newId) {
        SiliconSynth s = new SiliconSynth("Kyzen Network B200-HR", "kB200", address(vault));
        newId = vault.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(feed)));
    }

    function _pending(uint16 setting, uint256 marketId) internal view returns (uint256 value, uint256 effectiveAt) {
        return vault.pendingSettings(setting, marketId);
    }

    function _assertNothingQueued(uint16 setting, uint256 marketId) internal view {
        (uint256 value, uint256 effectiveAt) = _pending(setting, marketId);
        assertEq(value, 0, "no value queued");
        assertEq(effectiveAt, 0, "nothing queued");
    }

    /// No SettingQueued among the logs recorded since vm.recordLogs().
    function _assertNoQueueEvent() internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            assertTrue(logs[i].topics[0] != SiliconVault.SettingQueued.selector, "a setting was queued");
        }
    }

    function test_the_delay_and_the_setting_bits() public view {
        assertEq(vault.SETTING_DELAY(), DELAY);
        assertEq(vault.SETTING_BORROW_FEE(), BORROW);
        assertEq(vault.SETTING_LIQUIDATION_PENALTY(), PENALTY);
        assertEq(vault.SETTING_AUCTION_DURATION(), DURATION);
        assertEq(vault.SETTING_AUCTION_START_PREMIUM(), PREMIUM);
        assertEq(vault.SETTING_FEE_ROUTER(), ROUTER);
        assertEq(vault.SETTING_FEED(), FEED);
        assertEq(vault.SETTING_AUCTION_FLOOR(), FLOOR);
        assertEq(vault.openMarketCount(), 1);
        assertEq(vault.guardian(), address(0), "no guardian until the owner names one");
    }

    // ================================================================ before a market opens

    /// A market not yet open takes its own borrow fee, penalty and feed at once (no notice is owed
    /// to a position that cannot exist yet), whatever other markets are open. Its feed need not
    /// be ready to be set, as addMarket's need not; openMarket still needs it ready.
    function test_a_market_not_yet_open_takes_its_settings_at_once() public {
        uint256 m = _freshMarket();
        MockSiliconFeed other = new MockSiliconFeed(SYNTH_USD, FEED_MAX_AGE);
        vm.recordLogs();
        vault.setBorrowFee(m, 400);
        vault.setLiquidationPenalty(m, 800);
        vault.queueFeed(m, ISiliconFeed(address(other)));
        _assertNoQueueEvent();
        SiliconVault.Market memory mk = vault.market(m);
        assertEq(mk.borrowFeeBpsPerYear, 400);
        assertEq(mk.liquidationPenaltyBps, 800);
        assertEq(address(mk.feed), address(other));
        assertEq(mk.settings, BORROW + PENALTY);
        _assertNothingQueued(BORROW, m);
        _assertNothingQueued(PENALTY, m);
        _assertNothingQueued(FEED, m);

        vault.setMintFee(m, MINT_FEE_BPS);
        vault.setDebtCeiling(m, CEILING);
        vault.setMinDebt(m, MIN_DEBT);
        assertEq(vault.unsetSettings(m), FEED, "the new feed is not ready");
        other.setReady(true);
        vault.openMarket(m);
        assertEq(vault.openMarketCount(), 2);

        // Open, the same setters queue.
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingQueued(BORROW, m, 600, block.timestamp + DELAY);
        vault.setBorrowFee(m, 600);
        assertEq(vault.market(m).borrowFeeBpsPerYear, 400);
    }

    /// Emits the set event when the setting applies at once.
    function test_a_feed_set_at_once_emits() public {
        uint256 m = _freshMarket();
        MockSiliconFeed other = new MockSiliconFeed(SYNTH_USD, FEED_MAX_AGE);
        vm.expectEmit(address(vault));
        emit SiliconVault.FeedSet(m, address(other));
        vault.queueFeed(m, ISiliconFeed(address(other)));
    }

    /// The vault-wide settings apply at once until the first market opens, and queue from then on.
    /// A second market, not yet open, still takes its own settings at once.
    function test_vault_wide_settings_apply_at_once_until_a_market_opens() public {
        SiliconVault v = new SiliconVault(IERC20(address(kyzn)), IERC20(address(usdg)), IKyznUsdOracle(address(oracle)));
        SiliconSynth s = new SiliconSynth("Kyzen Network H100-HR", "kH100", address(v));
        uint256 m = v.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(feed)));
        address router2 = makeAddr("router2");

        vm.recordLogs();
        v.setAuctionDuration(3 hours);
        v.setAuctionStartPremium(1_500);
        v.setAuctionFloor(3_500);
        v.setFeeRouter(router2);
        // Again, still at once: a market added but not open holds no position.
        v.setAuctionDuration(2 hours);
        _assertNoQueueEvent();
        assertEq(v.auctionDuration(), 2 hours);
        assertEq(v.auctionStartPremiumBps(), 1_500);
        assertEq(v.auctionFloorBps(), 3_500);
        assertEq(v.feeRouter(), router2);
        assertEq(v.vaultSettings(), DURATION + PREMIUM + ROUTER + FLOOR);
        assertEq(v.openMarketCount(), 0);

        v.setMintFee(m, MINT_FEE_BPS);
        v.setBorrowFee(m, BORROW_FEE_BPS);
        v.setLiquidationPenalty(m, PENALTY_BPS);
        v.setDebtCeiling(m, CEILING);
        v.setMinDebt(m, MIN_DEBT);
        v.openMarket(m);
        assertEq(v.openMarketCount(), 1);

        vm.expectEmit(address(v));
        emit SiliconVault.SettingQueued(DURATION, 0, 4 hours, block.timestamp + DELAY);
        v.setAuctionDuration(4 hours);
        assertEq(v.auctionDuration(), 2 hours, "queued, not applied");

        SiliconSynth s2 = new SiliconSynth("Kyzen Network B200-HR", "kB200", address(v));
        uint256 m2 = v.addMarket(ISiliconSynth(address(s2)), ISiliconFeed(address(feed)));
        v.setBorrowFee(m2, 700);
        assertEq(v.market(m2).borrowFeeBpsPerYear, 700, "a closed market's own setting: at once");
    }

    // ================================================================ an open market's settings

    /// The borrow fee queues; for 24 hours the old rate runs, and anyone may apply the new one
    /// from then: the old rate is dripped up to that moment, the new one runs after it.
    function test_a_borrow_fee_change_waits_24_hours() public {
        vault.setMintFee(id, 0);
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 100e18);
        uint256 t0 = block.timestamp;

        vm.expectEmit(address(vault));
        emit SiliconVault.SettingQueued(BORROW, id, 1_000, t0 + DELAY);
        vault.setBorrowFee(id, 1_000);
        assertEq(_market().borrowFeeBpsPerYear, BORROW_FEE_BPS, "the rate in force is unchanged");
        (uint256 value, uint256 effectiveAt) = _pending(BORROW, id);
        assertEq(value, 1_000);
        assertEq(effectiveAt, t0 + DELAY);

        vm.warp(t0 + DELAY - 1);
        vm.prank(carol);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingNotDue.selector, BORROW, id, t0 + DELAY));
        vault.applySetting(BORROW, id);

        vm.warp(t0 + DELAY);
        uint256 oldRateFee = Math.mulDiv(100e18, BORROW_FEE_BPS * DELAY, 10_000 * 365 days);
        vm.expectEmit(address(vault));
        emit SiliconVault.FeesAccrued(id, oldRateFee);
        vm.expectEmit(address(vault));
        emit SiliconVault.BorrowFeeSet(id, 1_000);
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingApplied(BORROW, id, 1_000);
        vm.prank(carol); // anyone
        vault.applySetting(BORROW, id);
        assertEq(_market().borrowFeeBpsPerYear, 1_000);
        assertEq(synth.balanceOf(feeRouter), oldRateFee, "the old rate up to the apply");
        _assertNothingQueued(BORROW, id);

        vm.warp(block.timestamp + 365 days);
        vault.drip(id);
        assertEq(synth.balanceOf(feeRouter), oldRateFee + (100e18 + oldRateFee) / 10, "the new rate after it");
        _assertSupplyIsDebt();
    }

    /// The penalty queues: an auction started inside the notice takes the penalty in force, and
    /// keeps it after the new one applies; the next auction takes the new one.
    function test_a_penalty_change_waits_24_hours() public {
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
        uint256 t0 = block.timestamp;
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingQueued(PENALTY, id, 2_000, t0 + DELAY);
        vault.setLiquidationPenalty(id, 2_000);
        assertEq(_market().liquidationPenaltyBps, PENALTY_BPS);

        _warp(23 hours);
        oracle.set(0.9e18);
        vm.prank(bob);
        uint256 first = vault.startAuction(alice, id);
        uint256 firstPenalty = vault.auction(first).penalty;
        assertEq(firstPenalty, Math.mulDiv(vault.auction(first).debt, PENALTY_BPS, 10_000));

        _warp(1 hours);
        vm.expectEmit(address(vault));
        emit SiliconVault.LiquidationPenaltySet(id, 2_000);
        vault.applySetting(PENALTY, id);
        assertEq(_market().liquidationPenaltyBps, 2_000);
        assertEq(vault.auction(first).penalty, firstPenalty, "a running auction keeps its penalty");

        oracle.set(1e18);
        _deposit(bob, 300e18, 0);
        _mint(bob, 99e18);
        oracle.set(0.9e18);
        vm.prank(carol);
        uint256 second = vault.startAuction(bob, id);
        assertEq(vault.auction(second).penalty, Math.mulDiv(vault.auction(second).debt, 2_000, 10_000));
    }

    /// With a market open, the auction duration, starting premium, floor and fee router queue
    /// (under id 0) and apply 24 hours later, each through its own event.
    function test_vault_wide_settings_wait_24_hours_once_a_market_is_open() public {
        uint256 t0 = block.timestamp;
        address router2 = makeAddr("router2");
        uint256 due = t0 + DELAY;
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingQueued(DURATION, 0, 3 hours, due);
        vault.setAuctionDuration(3 hours);
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingQueued(PREMIUM, 0, 1_500, due);
        vault.setAuctionStartPremium(1_500);
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingQueued(FLOOR, 0, 3_500, due);
        vault.setAuctionFloor(3_500);
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingQueued(ROUTER, 0, uint160(router2), due);
        vault.setFeeRouter(router2);

        assertEq(vault.auctionDuration(), AUCTION_DURATION);
        assertEq(vault.auctionStartPremiumBps(), START_PREMIUM_BPS);
        assertEq(vault.auctionFloorBps(), AUCTION_FLOOR_BPS);
        assertEq(vault.feeRouter(), feeRouter);

        vm.warp(due - 1);
        uint16[4] memory settings = [DURATION, PREMIUM, FLOOR, ROUTER];
        for (uint256 i; i < 4; ++i) {
            vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingNotDue.selector, settings[i], 0, due));
            vault.applySetting(settings[i], 0);
        }

        vm.warp(due);
        vm.startPrank(carol); // anyone
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionDurationSet(3 hours);
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingApplied(DURATION, 0, 3 hours);
        vault.applySetting(DURATION, 0);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionStartPremiumSet(1_500);
        vault.applySetting(PREMIUM, 0);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionFloorSet(3_500);
        vault.applySetting(FLOOR, 0);
        vm.expectEmit(address(vault));
        emit SiliconVault.FeeRouterSet(router2);
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingApplied(ROUTER, 0, uint160(router2));
        vault.applySetting(ROUTER, 0);
        vm.stopPrank();

        assertEq(vault.auctionDuration(), 3 hours);
        assertEq(vault.auctionStartPremiumBps(), 1_500);
        assertEq(vault.auctionFloorBps(), 3_500);
        assertEq(vault.feeRouter(), router2);
        assertEq(vault.vaultSettings(), DURATION + PREMIUM + ROUTER + FLOOR);
        for (uint256 i; i < 4; ++i) {
            _assertNothingQueued(settings[i], 0);
        }
    }

    /// A second queue of the same setting replaces the first and restarts the 24 hours.
    function test_a_second_queue_replaces_the_first_and_restarts_the_delay() public {
        uint256 t0 = block.timestamp;
        vault.setAuctionFloor(3_000);
        vm.warp(t0 + 12 hours);
        vault.setAuctionFloor(5_000);
        (uint256 value, uint256 effectiveAt) = _pending(FLOOR, 0);
        assertEq(value, 5_000);
        assertEq(effectiveAt, t0 + 12 hours + DELAY);

        vm.warp(t0 + DELAY);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingNotDue.selector, FLOOR, 0, t0 + 12 hours + DELAY));
        vault.applySetting(FLOOR, 0);
        vm.warp(t0 + 12 hours + DELAY);
        vault.applySetting(FLOOR, 0);
        assertEq(vault.auctionFloorBps(), 5_000);
    }

    /// The mint fee, the debt ceiling, the minimum debt and the mint pause act at once on an open
    /// market: they never worsen a position already open.
    function test_the_mint_fee_ceiling_minimum_and_pause_stay_immediate() public {
        vm.recordLogs();
        vault.setMintFee(id, 30);
        vault.setDebtCeiling(id, 5e24);
        vault.setMinDebt(id, 5e18);
        vault.pauseMints(id);
        _assertNoQueueEvent();
        SiliconVault.Market memory mk = _market();
        assertEq(mk.mintFeeBps, 30);
        assertEq(mk.debtCeiling, 5e24);
        assertEq(mk.minDebt, 5e18);
        assertTrue(mk.mintsPaused);
    }

    /// The bounds are checked when the owner queues, as when it sets at once; nothing is queued by a
    /// call that reverts.
    function test_the_bounds_apply_when_queueing() public {
        bytes memory tooHigh = abi.encodeWithSelector(SiliconVault.BpsAboveMaximum.selector, 10_001, 10_000);
        vm.expectRevert(tooHigh);
        vault.setBorrowFee(id, 10_001);
        vm.expectRevert(tooHigh);
        vault.setLiquidationPenalty(id, 10_001);
        vm.expectRevert(tooHigh);
        vault.setAuctionStartPremium(10_001);
        vm.expectRevert(SiliconVault.ZeroAmount.selector);
        vault.setAuctionFloor(0);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.BpsAboveMaximum.selector, 10_000, 9_999));
        vault.setAuctionFloor(10_000);
        vm.expectRevert(SiliconVault.BadDuration.selector);
        vault.setAuctionDuration(0);
        vm.expectRevert(SiliconVault.ZeroAddress.selector);
        vault.setFeeRouter(address(0));
        vm.expectRevert(SiliconVault.ZeroAddress.selector);
        vault.queueFeed(id, ISiliconFeed(address(0)));
        bytes memory unknown = abi.encodeWithSelector(SiliconVault.UnknownMarket.selector, 9);
        vm.expectRevert(unknown);
        vault.queueFeed(9, ISiliconFeed(address(feed)));
        vm.expectRevert(unknown);
        vault.setBorrowFee(9, 1);
        vm.expectRevert(unknown);
        vault.setLiquidationPenalty(9, 1);

        _assertNothingQueued(BORROW, id);
        _assertNothingQueued(PENALTY, id);
        _assertNothingQueued(PREMIUM, 0);
        _assertNothingQueued(FLOOR, 0);
        _assertNothingQueued(DURATION, 0);
        _assertNothingQueued(ROUTER, 0);
        _assertNothingQueued(FEED, id);
    }

    // ================================================================ cancel and roles

    /// The owner cancels a queued setting: it can no longer be applied, and the value in force stays.
    function test_the_owner_cancels_a_queued_setting() public {
        vault.setBorrowFee(id, 1_000);
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingCancelled(BORROW, id);
        vault.cancelSetting(BORROW, id);
        _assertNothingQueued(BORROW, id);

        _warp(DELAY);
        bytes memory nothing = abi.encodeWithSelector(SiliconVault.NothingQueued.selector, BORROW, id);
        vm.expectRevert(nothing);
        vault.applySetting(BORROW, id);
        vm.expectRevert(nothing);
        vault.cancelSetting(BORROW, id);
        assertEq(_market().borrowFeeBpsPerYear, BORROW_FEE_BPS);
    }

    /// The guardian the owner names cancels too.
    function test_the_guardian_cancels_a_queued_setting() public {
        vm.expectEmit(address(vault));
        emit SiliconVault.GuardianSet(guardian);
        vault.setGuardian(guardian);
        assertEq(vault.guardian(), guardian);

        vault.setFeeRouter(alice);
        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingCancelled(ROUTER, 0);
        vault.cancelSetting(ROUTER, 0);

        _warp(DELAY);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NothingQueued.selector, ROUTER, 0));
        vault.applySetting(ROUTER, 0);
        assertEq(vault.feeRouter(), feeRouter);
    }

    /// Only the owner queues and names the guardian; only the owner or the guardian cancels (with
    /// no guardian named, only the owner; a guardian replaced or removed no longer can); anyone
    /// applies once due.
    function test_who_may_queue_cancel_and_apply() public {
        MockSiliconFeed next = new MockSiliconFeed(SYNTH_USD, FEED_MAX_AGE);
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(notOwner);
        vault.setGuardian(alice);
        vm.expectRevert(notOwner);
        vault.queueFeed(id, ISiliconFeed(address(next)));
        vm.expectRevert(notOwner);
        vault.setBorrowFee(id, 1_000);
        vm.expectRevert(notOwner);
        vault.setAuctionDuration(1);
        vm.stopPrank();

        vault.setBorrowFee(id, 1_000);
        bytes memory refused = abi.encodeWithSelector(SiliconVault.NotOwnerOrGuardian.selector);
        vm.prank(alice);
        vm.expectRevert(refused);
        vault.cancelSetting(BORROW, id);
        vm.prank(address(0)); // no guardian named: the zero address is not one
        vm.expectRevert(refused);
        vault.cancelSetting(BORROW, id);

        address replaced = makeAddr("replaced");
        vault.setGuardian(replaced);
        vault.setGuardian(guardian);
        vm.prank(replaced);
        vm.expectRevert(refused);
        vault.cancelSetting(BORROW, id);
        vault.setGuardian(address(0));
        vm.prank(guardian);
        vm.expectRevert(refused);
        vault.cancelSetting(BORROW, id);

        _warp(DELAY);
        vm.prank(alice);
        vault.applySetting(BORROW, id);
        assertEq(_market().borrowFeeBpsPerYear, 1_000);
    }

    /// Nothing queued, nothing to apply or cancel, for any setting and any id.
    function test_nothing_queued_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NothingQueued.selector, BORROW, 9));
        vault.applySetting(BORROW, 9);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NothingQueued.selector, FEED, id));
        vault.applyFeed(id);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NothingQueued.selector, uint16(1), id));
        vault.applySetting(1, id); // the mint fee never queues
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NothingQueued.selector, DURATION, 0));
        vault.cancelSetting(DURATION, 0);
    }

    // ================================================================ the sweep (final review I1)

    /// The review's proof of concept, now refused. With instant setters the owner could set a
    /// one-second auction and point the fee router at itself, then take a liquidatable position's
    /// whole collateral in two seconds (start, restart, close to the "fee router"). On an open
    /// market both changes wait 24 hours: an auction started inside the notice runs for the
    /// duration in force, and nothing reaches the owner.
    function test_the_owner_cannot_sweep_collateral_without_notice() public {
        _deposit(bob, 1_000e18, 1_000 * USDG_UNIT); // $2,000
        _mint(bob, 600e18); // 603 owed, $1,206: 165.8%
        oracle.set(0.75e18); // $1,750: 145.1%
        address owner_ = address(this);
        vault.setFeeRouter(owner_);
        vault.setAuctionDuration(1);
        assertEq(vault.feeRouter(), feeRouter, "the router in force");
        assertEq(vault.auctionDuration(), AUCTION_DURATION, "the duration in force");

        uint256 auctionId = vault.startAuction(bob, id);
        uint256 startedAt = block.timestamp;
        assertEq(vault.auction(auctionId).duration, AUCTION_DURATION);
        vm.warp(startedAt + 1);
        vm.expectRevert(
            abi.encodeWithSelector(SiliconVault.AuctionNotEnded.selector, auctionId, startedAt + AUCTION_DURATION)
        );
        vault.closeAuction(auctionId);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingNotDue.selector, ROUTER, 0, startedAt + DELAY));
        vault.applySetting(ROUTER, 0);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingNotDue.selector, DURATION, 0, startedAt + DELAY));
        vault.applySetting(DURATION, 0);
        assertEq(kyzn.balanceOf(owner_), 0);
        assertEq(usdg.balanceOf(owner_), 0);
    }

    /// Inside the notice a borrower sees SettingQueued and leaves: a full repay (no price read),
    /// then every unit of collateral out. When the changes apply, there is nothing left to take.
    function test_a_borrower_repays_and_withdraws_inside_the_notice() public {
        uint256 kyzn0 = kyzn.balanceOf(bob);
        uint256 usdg0 = usdg.balanceOf(bob);
        _deposit(bob, 1_000e18, 1_000 * USDG_UNIT);
        _mint(bob, 600e18);
        uint256 t0 = block.timestamp;
        vault.setFeeRouter(address(this));
        vault.setAuctionDuration(1);

        _warp(23 hours);
        vault.drip(id);
        uint256 debt = vault.debtOf(id, bob);
        uint256 fees = debt - synth.balanceOf(bob);
        vm.prank(feeRouter); // bob buys back the fees, to cover his whole debt
        assertTrue(synth.transfer(bob, fees));
        assertEq(_repay(bob, type(uint256).max), debt);
        _withdraw(bob, 1_000e18, 1_000 * USDG_UNIT);
        assertEq(kyzn.balanceOf(bob), kyzn0);
        assertEq(usdg.balanceOf(bob), usdg0);

        vm.warp(t0 + DELAY);
        vault.applySetting(ROUTER, 0);
        vault.applySetting(DURATION, 0);
        assertEq(vault.feeRouter(), address(this));
        assertEq(vault.auctionDuration(), 1);
        vm.expectRevert(SiliconVault.NoDebt.selector);
        vault.startAuction(bob, id);
        (uint256 k, uint256 u, uint256 shares) = _position(bob);
        assertEq(k + u + shares, 0);
    }

    // ================================================================ an auction keeps its terms

    /// Queues a 3-hour duration, a 10% premium, a 30% floor and `router2` as the fee router.
    function _queueNewAuctionTerms(address router2) internal {
        vault.setAuctionDuration(3 hours);
        vault.setAuctionStartPremium(1_000);
        vault.setAuctionFloor(3_000);
        vault.setFeeRouter(router2);
    }

    function _applyNewAuctionTerms() internal {
        vault.applySetting(DURATION, 0);
        vault.applySetting(PREMIUM, 0);
        vault.applySetting(FLOOR, 0);
        vault.applySetting(ROUTER, 0);
    }

    /// An auction records the terms in force when it starts: the duration, the starting premium,
    /// the floor and the fee router.
    function test_an_auction_records_the_terms_it_started_with() public {
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
        oracle.set(0.9e18);
        vm.prank(bob);
        SiliconVault.Auction memory a = vault.auction(vault.startAuction(alice, id));
        assertEq(a.duration, AUCTION_DURATION);
        assertEq(a.startPremiumBps, START_PREMIUM_BPS);
        assertEq(a.floorBps, AUCTION_FLOOR_BPS);
        assertEq(a.feeRouter, feeRouter);
    }

    /// New terms applied between an auction's end and its restart do not reach it: the restart
    /// reprices from the prices of the moment ($KYZN still $0.90, the synth $2.00) on the premium,
    /// floor and duration it started with, and its shortfall goes to the router it started with.
    /// The next auction takes the new terms.
    function test_terms_applied_before_a_restart_do_not_reach_it() public {
        address router2 = makeAddr("router2");
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
        oracle.set(0.9e18);
        vm.prank(bob);
        uint256 auctionId = vault.startAuction(alice, id);
        _queueNewAuctionTerms(router2);

        vm.warp(block.timestamp + DELAY); // the auction ended 18 hours ago, unsold
        feed.set(SYNTH_USD);
        _applyNewAuctionTerms();
        assertEq(vault.auctionDuration(), 3 hours);
        assertEq(vault.feeRouter(), router2);

        vault.closeAuction(auctionId); // the restart
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertTrue(a.restarted);
        assertEq(a.startedAt, block.timestamp);
        assertEq(a.duration, AUCTION_DURATION, "the duration it started with");
        assertEq(a.kyznStartPrice, 0.54e18, "0.9 x 1.2 / 2: the premium it started with");
        assertEq(a.kyznFloorPrice, 0.18e18, "0.9 x 0.4 / 2: the floor it started with");
        assertEq(a.feeRouter, feeRouter);

        vm.warp(block.timestamp + 3 hours);
        assertGt(vault.auctionPrice(auctionId), 0, "still running at the new 3 hours");
        vm.warp(a.startedAt + AUCTION_DURATION);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionClosed(auctionId, feeRouter, 300e18, 0, a.debt);
        vault.closeAuction(auctionId);
        assertEq(kyzn.balanceOf(feeRouter), 300e18, "the shortfall's collateral to the router it started with");
        assertEq(kyzn.balanceOf(router2), 0);

        // The next auction takes the terms now in force.
        feed.set(SYNTH_USD);
        oracle.set(1e18);
        _deposit(bob, 300e18, 0);
        _mint(bob, 99e18);
        oracle.set(0.9e18);
        vm.prank(carol);
        SiliconVault.Auction memory next = vault.auction(vault.startAuction(bob, id));
        assertEq(next.duration, 3 hours);
        assertEq(next.startPremiumBps, 1_000);
        assertEq(next.floorBps, 3_000);
        assertEq(next.feeRouter, router2);
        assertEq(next.kyznStartPrice, 0.495e18, "0.9 x 1.1 / 2");
        assertEq(next.kyznFloorPrice, 0.135e18, "0.9 x 0.3 / 2");
    }

    /// New terms applied while an auction runs do not reach it either: its price keeps falling over
    /// the six hours it started with, and a bid's penalty goes to the router it started with.
    function test_terms_applied_while_an_auction_runs_do_not_reach_it() public {
        address router2 = makeAddr("router2");
        _deposit(bidder, 100_000e18, 0);
        _mint(bidder, 10_000e18);
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
        uint256 t0 = block.timestamp;
        _queueNewAuctionTerms(router2);

        _warp(DELAY - 1 hours);
        oracle.set(0.9e18);
        vm.prank(bob);
        uint256 auctionId = vault.startAuction(alice, id);
        SiliconVault.Auction memory a = vault.auction(auctionId);

        vm.warp(t0 + DELAY); // an hour into the auction
        _applyNewAuctionTerms();
        uint256 start = Math.mulDiv(300e18, a.kyznStartPrice, 1e18, Math.Rounding.Ceil);
        uint256 floor = Math.mulDiv(300e18, a.kyznFloorPrice, 1e18, Math.Rounding.Ceil);
        uint256 lot = floor + Math.mulDiv(start - floor, 5 hours, AUCTION_DURATION, Math.Rounding.Ceil);
        assertEq(vault.auctionPrice(auctionId), lot, "five of its six hours left");

        uint256 oldRouterSynth = synth.balanceOf(feeRouter);
        vm.prank(bidder);
        (uint256 paid,,) = vault.bid(auctionId, type(uint256).max);
        assertEq(paid, a.debt + a.penalty, "the whole debt and penalty");
        assertEq(synth.balanceOf(feeRouter) - oldRouterSynth, a.penalty, "the penalty to the router it started with");
        assertEq(synth.balanceOf(router2), 0);
        assertEq(vault.auction(auctionId).account, address(0), "closed");
        _assertSupplyIsDebt();
    }

    // ================================================================ feed migration (I2)

    /// On an open market the owner queues a new feed; anyone applies it 24 hours later, and only
    /// while it is ready. The market then prices from it.
    function test_a_feed_change_waits_24_hours_and_needs_a_ready_feed() public {
        MockSiliconFeed next = new MockSiliconFeed(4e18, FEED_MAX_AGE);
        uint256 t0 = block.timestamp;
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingQueued(FEED, id, uint160(address(next)), t0 + DELAY);
        vault.queueFeed(id, ISiliconFeed(address(next)));
        assertEq(address(_market().feed), address(feed), "the feed in force is unchanged");

        vm.warp(t0 + DELAY - 1);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingNotDue.selector, FEED, id, t0 + DELAY));
        vault.applyFeed(id);
        vm.warp(t0 + DELAY);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.FeedNotReady.selector, address(next)));
        vault.applyFeed(id);

        next.setReady(true);
        next.set(4e18);
        vm.expectEmit(address(vault));
        emit SiliconVault.FeedSet(id, address(next));
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingApplied(FEED, id, uint160(address(next)));
        vm.prank(carol); // anyone
        vault.applyFeed(id);
        assertEq(address(_market().feed), address(next));
        _assertNothingQueued(FEED, id);

        // At $4.00 a mint of 50 synth (50.25 owed, $201) against $300 is 149.25%; 49 passes.
        _deposit(alice, 300e18, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, 14_925, 15_000));
        vault.mint(id, 50e18);
        uint256 syncs = next.syncs();
        _mint(alice, 49e18);
        assertEq(next.syncs(), syncs + 1, "the vault reads the new feed");
    }

    /// applySetting(SETTING_FEED, id) is the same as applyFeed(id).
    function test_applySetting_applies_a_queued_feed_too() public {
        MockSiliconFeed next = new MockSiliconFeed(SYNTH_USD, FEED_MAX_AGE);
        next.setReady(true);
        vault.queueFeed(id, ISiliconFeed(address(next)));
        vm.warp(block.timestamp + DELAY);
        vault.applySetting(FEED, id);
        assertEq(address(_market().feed), address(next));
    }

    /// The guardian (or the owner) may cancel a queued feed.
    function test_the_guardian_cancels_a_queued_feed() public {
        MockSiliconFeed next = new MockSiliconFeed(SYNTH_USD, FEED_MAX_AGE);
        next.setReady(true);
        vault.setGuardian(guardian);
        vault.queueFeed(id, ISiliconFeed(address(next)));
        vm.prank(guardian);
        vm.expectEmit(address(vault));
        emit SiliconVault.SettingCancelled(FEED, id);
        vault.cancelSetting(FEED, id);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NothingQueued.selector, FEED, id));
        vault.applyFeed(id);
        assertEq(address(_market().feed), address(feed));
    }

    /// An ended auction whose feed never turns fresh again waits for ever (no force-close): a
    /// migrated feed lets it restart. Alice owes 99.495; $KYZN falls to $0.90 and her auction
    /// ends unsold; the feed then stops. On the new feed ($2.50) the restart starts at
    /// 0.9 x 1.2 / 2.5 = 0.432 synth a $KYZN and floors at 0.9 x 0.4 / 2.5 = 0.144.
    function test_a_migrated_feed_lets_a_stuck_auction_restart() public {
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
        oracle.set(0.9e18);
        vm.prank(bob);
        uint256 auctionId = vault.startAuction(alice, id);
        vm.warp(block.timestamp + AUCTION_DURATION);

        feed.setFreshForLiquidation(false);
        bytes memory stale = abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed));
        vm.expectRevert(stale);
        vault.closeAuction(auctionId);

        MockSiliconFeed next = new MockSiliconFeed(2.5e18, FEED_MAX_AGE);
        next.setReady(true);
        vault.queueFeed(id, ISiliconFeed(address(next)));
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(stale);
        vault.closeAuction(auctionId);

        next.set(2.5e18);
        vault.applyFeed(id);
        vm.expectEmit(address(vault));
        emit SiliconVault.AuctionRestarted(auctionId, 0.432e18, 0.48e30);
        vault.closeAuction(auctionId);
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertTrue(a.restarted);
        assertEq(a.startedAt, block.timestamp);
        assertEq(a.kyznFloorPrice, 0.144e18);
        assertEq(a.kyzn, 300e18);
        _assertSupplyIsDebt();
    }

    // ================================================================ a zero price (M1)

    /// A feed that says the synth is worth nothing stops every priced action with ZeroPrice: a
    /// mint would otherwise owe a debt worth nothing, and an auction could not be priced. Repay and
    /// deposit read no price and still work.
    function test_a_zero_synth_price_reverts_every_priced_action() public {
        _deposit(alice, 300e18, 0);
        _mint(alice, 99e18);
        _deposit(carol, 300e18, 0);
        _mint(carol, 50e18);
        oracle.set(0.9e18);
        vm.prank(bob);
        uint256 auctionId = vault.startAuction(alice, id);

        feed.set(0);
        bytes memory zero = abi.encodeWithSelector(SiliconVault.ZeroPrice.selector, address(feed));
        vm.startPrank(carol);
        vm.expectRevert(zero);
        vault.mint(id, 1e18);
        vm.expectRevert(zero);
        vault.withdraw(id, 1e18, 0);
        vm.stopPrank();
        oracle.set(0.3e18); // carol would be under 150%
        vm.prank(bob);
        vm.expectRevert(zero);
        vault.startAuction(carol, id);

        vm.warp(block.timestamp + AUCTION_DURATION);
        feed.set(0);
        vm.expectRevert(zero);
        vault.closeAuction(auctionId);

        _repay(carol, 1e18);
        _deposit(carol, 1e18, 0);
    }
}
