// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IMarketCalendar} from "../../src/silicon/interfaces/IMarketCalendar.sol";
import {MarketCalendar} from "../../src/silicon/MarketCalendar.sol";
import {StockIndexFeed} from "../../src/silicon/StockIndexFeed.sol";
import {MockRoundFeed} from "./mocks/SiliconMocks.sol";

/// A feed that works until it is told to misbehave: then both round reads revert, burn all the gas
/// they are given, or answer with too few bytes (32, 64 or 159 of the 160 owed). Its round id can be set. Stands in for a broken or hostile aggregator.
contract BreakableFeed {
    enum Mode {
        Working,
        Reverts,
        BurnsGas,
        ShortAnswer,
        Answer64,
        Answer159
    }

    uint8 public immutable decimals;
    Mode public mode;
    int256 public answer;
    uint256 public updatedAt;
    uint80 public round = 1;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function setRound(uint80 round_) external {
        round = round_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        _misbehave();
        return (round, answer, updatedAt, updatedAt, round);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        _misbehave();
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    function _misbehave() private view {
        if (mode == Mode.Reverts) revert("broken");
        if (mode == Mode.BurnsGas) {
            while (true) {}
        }
        if (mode == Mode.ShortAnswer) {
            assembly {
                return(0, 0x20)
            }
        }
        if (mode == Mode.Answer64) {
            assembly {
                return(0, 0x40)
            }
        }
        if (mode == Mode.Answer159) {
            assembly {
                return(0, 0x9f)
            }
        }
    }
}

/// The stock index feed (SPEC 3.5): a basket of Chainlink stock prices valued at 100 USD on
/// day one, fresh for mints only inside the calendar window and under 24 hours, fresh for
/// liquidations under 96 hours, stopped by a component's jump until the guardian clears it.
contract StockIndexFeedTest is Test {
    // Monday 2026-10-05 00:00 UTC, and the same day at 15:00 UTC (inside the window).
    uint256 internal constant MON = 1_791_158_400;
    uint256 internal constant MON_15 = 1_791_212_400;

    int256 internal constant NVDA_PX = 200e8;
    int256 internal constant AMD_PX = 100e8;

    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    MarketCalendar internal cal;
    MockRoundFeed internal nvda;
    MockRoundFeed internal amd;
    StockIndexFeed internal feed;
    uint256 internal deployedAt;

    function setUp() public {
        vm.warp(MON_15);
        cal = new MarketCalendar(address(this));
        nvda = new MockRoundFeed(8, NVDA_PX);
        amd = new MockRoundFeed(8, AMD_PX);
        feed = _deploy(_two(address(nvda), address(amd)));
        feed.setGuardian(guardian);
        deployedAt = block.timestamp;
    }

    function _two(address a, address b) internal pure returns (address[] memory feeds) {
        feeds = new address[](2);
        feeds[0] = a;
        feeds[1] = b;
    }

    function _deploy(address[] memory feeds) internal returns (StockIndexFeed) {
        return new StockIndexFeed("SEMI-1 / USD", cal, feeds, address(this));
    }

    function _ceilDiv(uint256 a, uint256 b) internal pure returns (uint256) {
        return (a + b - 1) / b;
    }

    /// The guardian clears component `i` at the round the feed is on now.
    function _clear(uint256 i) internal {
        (address f,,) = feed.component(i);
        uint80 round = MockRoundFeed(f).latestRound();
        vm.prank(guardian);
        feed.clearJump(i, round);
    }

    // ---------------------------------------------------------------- construction

    function test_startsAt100WithEqualDollarWeights() public view {
        assertEq(feed.componentCount(), 2);
        (address f0, uint8 d0, uint256 q0) = feed.component(0);
        (address f1, uint8 d1, uint256 q1) = feed.component(1);
        assertEq(f0, address(nvda));
        assertEq(f1, address(amd));
        assertEq(d0, 8);
        assertEq(d1, 8);
        assertEq(q0, 0.25e18); // 50 USD of a 200 USD stock
        assertEq(q1, 0.5e18); // 50 USD of a 100 USD stock
        (uint256 price, uint256 updatedAt) = feed.latestPrice();
        assertEq(price, 100e18);
        assertEq(updatedAt, deployedAt);
        assertEq(feed.description(), "SEMI-1 / USD");
        assertEq(address(feed.calendar()), address(cal));
        assertEq(feed.owner(), address(this));
        assertEq(feed.BASE_PRICE(), 100e18);
        assertEq(feed.MINT_MAX_AGE(), 24 hours);
        assertEq(feed.LIQUIDATION_MAX_AGE(), 96 hours);
        assertEq(feed.JUMP_BPS(), 3_000);
        assertEq(feed.QUANTITY_DELAY(), 24 hours);
        assertEq(feed.MAX_COMPONENTS(), 4);
    }

    /// 100 USD does not divide by 3: each component rounds down, so the index starts just under 100.
    function test_oddBasketRoundsEachComponentDown() public {
        MockRoundFeed third = new MockRoundFeed(8, 100e8);
        address[] memory feeds = new address[](3);
        feeds[0] = address(nvda);
        feeds[1] = address(amd);
        feeds[2] = address(third);
        StockIndexFeed odd = _deploy(feeds);
        (uint256 price,) = odd.latestPrice();
        assertLe(price, 100e18);
        assertGt(price, 100e18 - 1e6);
        (,, uint256 q2) = odd.component(2);
        assertEq(q2, 333_333_333_333_333_333); // floor(33.33..e18 * 1e18 / 100e18)
    }

    function test_fourComponentsAndMixedDecimals() public {
        MockRoundFeed a = new MockRoundFeed(18, 25e18);
        MockRoundFeed b = new MockRoundFeed(6, 50e6);
        address[] memory feeds = new address[](4);
        feeds[0] = address(a);
        feeds[1] = address(b);
        feeds[2] = address(nvda);
        feeds[3] = address(amd);
        StockIndexFeed four = _deploy(feeds);
        (uint256 price,) = four.latestPrice();
        assertEq(price, 100e18);
        (,, uint256 q0) = four.component(0);
        (, uint8 d1, uint256 q1) = four.component(1);
        assertEq(q0, 1e18); // 25 USD of a 25 USD stock
        assertEq(d1, 6);
        assertEq(q1, 0.5e18);
    }

    function test_constructorRejects() public {
        // No components, and more than four.
        vm.expectRevert(StockIndexFeed.BadComponents.selector);
        _deploy(new address[](0));
        address[] memory five = new address[](5);
        for (uint256 i; i < 5; ++i) {
            five[i] = address(new MockRoundFeed(8, 100e8));
        }
        vm.expectRevert(StockIndexFeed.BadComponents.selector);
        _deploy(five);

        // A zero feed address, and a zero calendar.
        vm.expectRevert(StockIndexFeed.ZeroAddress.selector);
        _deploy(_two(address(nvda), address(0)));
        vm.expectRevert(StockIndexFeed.ZeroAddress.selector);
        new StockIndexFeed("X", IMarketCalendar(address(0)), _two(address(nvda), address(amd)), address(this));

        // A feed with more than 18 decimals.
        MockRoundFeed wide = new MockRoundFeed(19, 100e19);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.BadFeed.selector, address(wide)));
        _deploy(_two(address(nvda), address(wide)));

        // A feed whose current answer is not positive, and one that cannot be read at all.
        MockRoundFeed zero = new MockRoundFeed(8, 0);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.BadFeed.selector, address(zero)));
        _deploy(_two(address(nvda), address(zero)));
        MockRoundFeed negative = new MockRoundFeed(8, -1);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.BadFeed.selector, address(negative)));
        _deploy(_two(address(nvda), address(negative)));
        BreakableFeed broken = new BreakableFeed(8, 100e8);
        broken.setMode(BreakableFeed.Mode.Reverts);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.BadFeed.selector, address(broken)));
        _deploy(_two(address(nvda), address(broken)));

        // A feed on round 0 has no round to measure from.
        BreakableFeed roundZero = new BreakableFeed(8, 100e8);
        roundZero.setRound(0);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.BadFeed.selector, address(roundZero)));
        _deploy(_two(address(nvda), address(roundZero)));

        // The same feed twice would count one stock twice.
        vm.expectRevert(StockIndexFeed.BadComponents.selector);
        _deploy(_two(address(nvda), address(nvda)));
        address[] memory three = new address[](3);
        three[0] = address(nvda);
        three[1] = address(amd);
        three[2] = address(nvda);
        vm.expectRevert(StockIndexFeed.BadComponents.selector);
        _deploy(three);
    }

    /// Each component announces its feed, decimals, quantity and deployment round.
    function test_constructorEmitsComponentAdded() public {
        vm.expectEmit(true, false, false, true);
        emit StockIndexFeed.ComponentAdded(0, address(nvda), 8, 0.25e18, 1);
        vm.expectEmit(true, false, false, true);
        emit StockIndexFeed.ComponentAdded(1, address(amd), 8, 0.5e18, 1);
        _deploy(_two(address(nvda), address(amd)));
    }

    // ---------------------------------------------------------------- price

    function test_priceFollowsComponents() public {
        nvda.set(220e8);
        (uint256 price,) = feed.latestPrice();
        assertEq(price, 105e18); // 0.25 * 220 + 0.5 * 100
        amd.set(80e8);
        (price,) = feed.latestPrice();
        assertEq(price, 95e18); // 0.25 * 220 + 0.5 * 80
    }

    function test_updatedAtIsTheOldestComponent() public {
        vm.warp(block.timestamp + 1 hours);
        nvda.set(NVDA_PX);
        (, uint256 updatedAt) = feed.latestPrice();
        assertEq(updatedAt, deployedAt); // AMD has not updated
        amd.set(AMD_PX);
        (, updatedAt) = feed.latestPrice();
        assertEq(updatedAt, block.timestamp);
    }

    function test_nonPositiveAnswerIsStaleAndPriceZero() public {
        nvda.set(0);
        (uint256 price, uint256 updatedAt) = feed.latestPrice();
        assertEq(price, 0);
        assertEq(updatedAt, 0);
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());
        nvda.set(-5);
        (price, updatedAt) = feed.latestPrice();
        assertEq(price, 0);
        assertEq(updatedAt, 0);
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());
        nvda.set(NVDA_PX);
        assertTrue(feed.jumped(0)); // the bad round is behind the new one: the breaker holds
        assertFalse(feed.isFresh());
        _clear(0);
        assertTrue(feed.isFresh());
    }

    // ---------------------------------------------------------------- freshness

    function test_freshForMintsOnlyInWindowAndUnder24h() public {
        assertTrue(feed.isFresh()); // Monday 15:00
        vm.warp(MON + 20 hours); // the window has closed; the prices are 5 hours old
        assertFalse(feed.isFresh());
        vm.warp(MON_15 + 24 hours); // Tuesday 15:00: exactly 24 hours old is still fresh
        assertTrue(feed.isFresh());
        vm.warp(MON_15 + 24 hours + 1);
        assertFalse(feed.isFresh());
        nvda.set(NVDA_PX);
        assertFalse(feed.isFresh()); // AMD is still stale
        amd.set(AMD_PX);
        assertTrue(feed.isFresh());
    }

    function test_liquidationFreshnessIs96hAnywhere() public {
        uint256 fri19 = MON + 4 days + 19 hours;
        vm.warp(fri19);
        nvda.set(NVDA_PX);
        amd.set(AMD_PX);
        assertTrue(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());
        vm.warp(MON + 5 days + 10 hours); // Saturday 10:00
        assertFalse(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());
        vm.warp(fri19 + 96 hours); // exactly 96 hours old is still fresh
        assertTrue(feed.isFreshForLiquidation());
        vm.warp(fri19 + 96 hours + 1);
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());
    }

    function test_mintWindowFollowsTheCalendar() public {
        uint256[] memory d = new uint256[](1);
        d[0] = (MON + 1 days) / 1 days; // Tuesday a holiday
        cal.setDays(d, MarketCalendar.DayKind.Closed);
        vm.warp(MON_15 + 1 days);
        nvda.set(NVDA_PX);
        amd.set(AMD_PX);
        assertFalse(feed.isFresh()); // fresh prices, closed day
        assertTrue(feed.isFreshForLiquidation());
    }

    // ---------------------------------------------------------------- jumps

    function test_exactly30PercentIsNotAJump() public {
        nvda.set(260e8); // +30.0%
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());
        nvda.set(182e8); // 260 to 182 is -30.0%
        assertFalse(feed.jumped(0));
        nvda.set(1_000e8); // a new jump
        assertTrue(feed.jumped(0));
        _clear(0);
        nvda.set(700e8); // 1000 to 700 is -30.0%
        assertFalse(feed.jumped(0));
        nvda.set(489e8); // 700 to 489 is -30.14%
        assertTrue(feed.jumped(0));
    }

    /// The breaker latches: a clean round after a jump does not release it, a sync does not skip
    /// it, and only the guardian's clear does.
    function test_jumpLatchesUntilTheGuardianClears() public {
        nvda.set(261e8); // round 2: +30.5%
        nvda.set(262e8); // round 3: a clean move from round 2
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());

        vm.prank(alice);
        feed.sync();
        assertEq(feed.checkedRound(0), 1); // the checked round stops before the jump
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());

        nvda.set(263e8);
        feed.sync();
        assertEq(feed.checkedRound(0), 1);
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());

        _clear(0); // the guardian clears at the latest round
        assertEq(feed.checkedRound(0), 4);
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());
    }

    /// Anyone's sync() records the clean rounds since the last one, per component.
    function test_syncAdvancesCheckedRoundOverCleanRounds() public {
        nvda.set(210e8);
        nvda.set(220e8);
        nvda.set(230e8); // rounds 2 to 4
        assertEq(feed.checkedRound(0), 1);
        assertTrue(feed.isFresh()); // unsynced clean rounds are walked on the fly

        vm.expectEmit(true, false, false, true, address(feed));
        emit StockIndexFeed.RoundChecked(0, 4);
        vm.prank(alice);
        feed.sync();
        assertEq(feed.checkedRound(0), 4);
        assertEq(feed.checkedRound(1), 1); // AMD has no new round
        assertTrue(feed.isFresh());

        // Nothing new to record: no event, nothing moves.
        vm.recordLogs();
        feed.sync();
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(feed.checkedRound(0), 4);
        assertEq(feed.checkedRound(1), 1);
    }

    /// sync() advances to the last clean round and not one past a jump, however many rounds follow.
    function test_syncStopsBeforeAJump() public {
        nvda.set(210e8); // round 2, clean
        nvda.set(300e8); // round 3: +42.9%
        nvda.set(305e8); // round 4, clean after the jump
        feed.sync();
        assertEq(feed.checkedRound(0), 2);
        assertTrue(feed.jumped(0));
        feed.sync();
        assertEq(feed.checkedRound(0), 2);
        assertTrue(feed.jumped(0));
    }

    function _rounds(MockRoundFeed f, uint256 n) internal {
        for (uint256 k; k < n; ++k) {
            f.set(NVDA_PX + int256(k % 2)); // tiny moves
        }
    }

    /// A view walks at most MAX_SCAN (16) rounds past the checked one; more than that is not
    /// fresh until sync() has caught up, 16 at a time.
    function test_moreThanSixteenUnsyncedRoundsNeedSync() public {
        assertEq(feed.MAX_SCAN(), 16);
        _rounds(nvda, 16); // rounds 2 to 17: sixteen to walk
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());

        nvda.set(NVDA_PX); // round 18: seventeen to walk
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());
        feed.sync();
        assertEq(feed.checkedRound(0), 17); // 1 + 16: partial progress
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());

        _rounds(nvda, 40); // rounds 19 to 58: 41 past the checked round
        assertFalse(feed.isFresh());
        feed.sync();
        assertEq(feed.checkedRound(0), 33);
        assertFalse(feed.isFresh()); // 25 left
        feed.sync();
        assertEq(feed.checkedRound(0), 49);
        assertTrue(feed.isFresh()); // 9 left: back within a view's walk
        feed.sync();
        assertEq(feed.checkedRound(0), 58);
        assertTrue(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());
    }

    /// A jump deep in a long backlog is found by the sync step that reaches it.
    function test_syncFindsAJumpInALongBacklog() public {
        _rounds(nvda, 20); // rounds 2 to 21, clean
        nvda.set(900e8); // round 22: a jump
        _rounds(nvda, 5);
        feed.sync();
        assertEq(feed.checkedRound(0), 17);
        feed.sync();
        assertEq(feed.checkedRound(0), 21); // stops before round 22
        feed.sync();
        assertEq(feed.checkedRound(0), 21);
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());
    }

    /// A round below the checked one (a feed that went backwards) is not clean; the checked
    /// round never moves backwards on its own.
    function test_roundBelowCheckedIsNotClean() public {
        BreakableFeed flaky = new BreakableFeed(8, 100e8);
        StockIndexFeed f = _deploy(_two(address(nvda), address(flaky)));
        f.setGuardian(guardian);
        flaky.setRound(5);
        vm.prank(guardian);
        f.clearJump(1, 5);
        assertEq(f.checkedRound(1), 5);
        assertTrue(f.isFresh());
        flaky.setRound(3);
        assertTrue(f.jumped(1));
        assertFalse(f.isFresh());
        f.sync();
        assertEq(f.checkedRound(1), 5);
        flaky.setRound(5);
        assertFalse(f.jumped(1));
        assertTrue(f.isFresh());
        flaky.setRound(8); // later rounds walk from the checked one (the mock answers the same price)
        assertFalse(f.jumped(1));
        f.sync();
        assertEq(f.checkedRound(1), 8);
    }

    /// Round 0 is never a round to trust: it reads as a jump and the guardian cannot accept it.
    function test_roundZeroIsNeverClean() public {
        BreakableFeed flaky = new BreakableFeed(8, 100e8);
        StockIndexFeed f = _deploy(_two(address(nvda), address(flaky)));
        f.setGuardian(guardian);
        assertTrue(f.isFresh());
        flaky.setRound(0);
        assertTrue(f.jumped(1));
        assertFalse(f.isFresh());
        assertFalse(f.isFreshForLiquidation());
        f.sync();
        assertEq(f.checkedRound(1), 1);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.RoundMismatch.selector, 0, 0));
        vm.prank(guardian);
        f.clearJump(1, 0);
        assertTrue(f.jumped(1));
    }

    /// A quantity correction (a split needs none; this is a feed moving to a basis that quotes
    /// half the price): the quantity applying before the new basis prints stops the feed until
    /// the guardian clears it, as the print itself does.
    function test_appliedQuantityStopsTheFeedUntilTheGuardianClears() public {
        feed.queueQuantity(0, 0.5e18);
        vm.warp(block.timestamp + 24 hours);
        nvda.set(NVDA_PX);
        amd.set(AMD_PX);
        assertTrue(feed.isFresh());
        assertFalse(feed.needsClear(0));

        vm.prank(alice); // anyone may apply it
        feed.applyQuantity(0);
        assertTrue(feed.needsClear(0));
        assertTrue(feed.jumped(0));
        assertFalse(feed.jumped(1));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());

        nvda.set(100e8); // the new basis prints
        feed.sync();
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());

        _clear(0);
        assertFalse(feed.needsClear(0));
        assertTrue(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());
        (uint256 price,) = feed.latestPrice();
        assertEq(price, 100e18); // 0.5 * 100 + 0.5 * 100
    }

    /// The guardian cannot clear a component while its quantity is queued: a print on the new
    /// basis that comes first stays stopped until the quantity is applied, and then one clear
    /// accepts both.
    function test_clearJumpWaitsForAQueuedQuantityToApply() public {
        feed.queueQuantity(0, 0.5e18);
        nvda.set(100e8); // round 2: the new basis prints before the quantity is due
        assertTrue(feed.jumped(0));

        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityPending.selector, 0));
        vm.prank(guardian);
        feed.clearJump(0, 2);
        assertEq(feed.checkedRound(0), 1);
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());

        // A component with nothing queued is unaffected.
        amd.set(50e8);
        assertTrue(feed.jumped(1));
        _clear(1);
        assertFalse(feed.jumped(1));

        vm.warp(block.timestamp + 24 hours);
        nvda.set(100e8); // round 3
        amd.set(50e8);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityPending.selector, 0)); // due is not applied
        vm.prank(guardian);
        feed.clearJump(0, 3);

        feed.applyQuantity(0);
        assertTrue(feed.needsClear(0));
        assertFalse(feed.isFresh());
        _clear(0); // now it passes, and ends the stop the application began
        assertFalse(feed.needsClear(0));
        assertEq(feed.checkedRound(0), 3);
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());
        (uint256 price,) = feed.latestPrice();
        assertEq(price, 0.5e18 * 100 + 0.5e18 * 50); // 0.5 * 100 + 0.5 * 50
    }

    /// A cancelled quantity no longer holds the clear back.
    function test_clearJumpPassesOnceTheQuantityIsCancelled() public {
        feed.queueQuantity(0, 0.5e18);
        nvda.set(100e8);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityPending.selector, 0));
        vm.prank(guardian);
        feed.clearJump(0, 2);

        vm.prank(guardian);
        feed.cancelQuantity(0);
        _clear(0);
        assertEq(feed.checkedRound(0), 2);
        assertFalse(feed.needsClear(0));
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());
    }

    /// The pending-quantity check sits after the role and component checks and before the feed
    /// and round checks.
    function test_clearJumpCheckOrder() public {
        BreakableFeed flaky = new BreakableFeed(8, 100e8);
        StockIndexFeed f = _deploy(_two(address(nvda), address(flaky)));
        f.setGuardian(guardian);
        f.queueQuantity(1, 1e18);

        vm.expectRevert(StockIndexFeed.NotGuardian.selector); // role first
        vm.prank(alice);
        f.clearJump(1, 1);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.UnknownComponent.selector, 2)); // then the component
        vm.prank(guardian);
        f.clearJump(2, 1);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityPending.selector, 1)); // wrong round id
        vm.prank(guardian);
        f.clearJump(1, 99);
        flaky.setMode(BreakableFeed.Mode.Reverts);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityPending.selector, 1)); // unreadable feed
        vm.prank(guardian);
        f.clearJump(1, 1);

        f.cancelQuantity(1); // the owner cancels; then the feed and round checks speak
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.BadFeed.selector, address(flaky)));
        vm.prank(guardian);
        f.clearJump(1, 1);
        flaky.setMode(BreakableFeed.Mode.Working);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.RoundMismatch.selector, 99, 1));
        vm.prank(guardian);
        f.clearJump(1, 99);
    }

    function test_jumpOver30PercentStopsBothUntilCleared() public {
        nvda.set(261e8); // 200 to 261 is +30.5%
        assertTrue(feed.jumped(0));
        assertFalse(feed.jumped(1));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());

        vm.expectRevert(StockIndexFeed.NotGuardian.selector);
        vm.prank(alice);
        feed.clearJump(0, 2);

        vm.expectEmit(true, false, false, true, address(feed));
        emit StockIndexFeed.JumpCleared(0, 2);
        _clear(0);
        assertEq(feed.checkedRound(0), 2);
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());

        nvda.set(262e8); // a normal round after the cleared one
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());

        nvda.set(400e8); // a second jump stops it again
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());
    }

    function test_jumpDownStopsToo() public {
        amd.set(69e8); // 100 to 69 is -31%
        assertTrue(feed.jumped(1));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());
    }

    /// The guardian clears exactly the round it checked: a stale or invented round id reverts, and
    /// so does a clear that lands after a newer round has.
    function test_clearJumpNeedsTheCurrentRound() public {
        nvda.set(261e8); // round 2, a jump the guardian looks at
        assertTrue(feed.jumped(0));

        vm.startPrank(guardian);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.RoundMismatch.selector, 1, 2)); // an old round
        feed.clearJump(0, 1);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.RoundMismatch.selector, 99, 2)); // a round to come
        feed.clearJump(0, 99);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.RoundMismatch.selector, 0, 2));
        feed.clearJump(0, 0);
        vm.stopPrank();
        assertEq(feed.checkedRound(0), 1); // nothing was accepted
        assertTrue(feed.jumped(0));

        // A new round (a second, worse print) lands between the guardian's check and its clear.
        nvda.set(500e8);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.RoundMismatch.selector, 2, 3));
        vm.prank(guardian);
        feed.clearJump(0, 2);
        assertEq(feed.checkedRound(0), 1);
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());

        // The round the guardian checks now clears.
        vm.prank(guardian);
        feed.clearJump(0, 3);
        assertEq(feed.checkedRound(0), 3);
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());
    }

    /// The round check comes after the role check, and an unreadable feed cannot be cleared.
    function test_clearJumpRoleAndUnreadableFeed() public {
        vm.expectRevert(StockIndexFeed.NotGuardian.selector);
        vm.prank(alice);
        feed.clearJump(0, 1);

        BreakableFeed flaky = new BreakableFeed(8, 100e8);
        StockIndexFeed f = _deploy(_two(address(nvda), address(flaky)));
        f.setGuardian(guardian);
        flaky.setMode(BreakableFeed.Mode.Reverts);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.BadFeed.selector, address(flaky)));
        vm.prank(guardian);
        f.clearJump(1, 1);
    }

    /// The deployment round is the reference price: accepted without the guardian, even when the
    /// round before it cannot be read.
    function test_deploymentRoundIsAccepted() public {
        assertEq(feed.checkedRound(0), 1);
        assertEq(feed.checkedRound(1), 1);
        nvda.setPreviousUnreadable(true);
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());
    }

    function test_unreadablePreviousRoundCountsAsJump() public {
        nvda.set(NVDA_PX); // round 2, a normal move
        assertFalse(feed.jumped(0));
        nvda.setPreviousUnreadable(true);
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());
        assertFalse(feed.isFreshForLiquidation());
        _clear(0);
        assertFalse(feed.jumped(0));
        assertTrue(feed.isFresh());
    }

    function test_unknownComponentReverts() public {
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.UnknownComponent.selector, 2));
        feed.jumped(2);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.UnknownComponent.selector, 2));
        feed.component(2);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.UnknownComponent.selector, 2));
        vm.prank(guardian);
        feed.clearJump(2, 1);
    }

    // ---------------------------------------------------------------- pause

    function test_pauseStopsMintsNotLiquidations() public {
        vm.expectRevert(StockIndexFeed.NotGuardian.selector);
        vm.prank(alice);
        feed.pause();
        vm.expectRevert(StockIndexFeed.NotGuardian.selector);
        feed.pause(); // the owner is not the guardian

        vm.prank(guardian);
        feed.pause();
        assertTrue(feed.paused());
        assertFalse(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());

        vm.expectRevert(StockIndexFeed.NotGuardian.selector);
        vm.prank(alice);
        feed.unpause();
        vm.prank(guardian);
        feed.unpause();
        assertFalse(feed.paused());
        assertTrue(feed.isFresh());
    }

    // ---------------------------------------------------------------- quantity changes

    function test_quantityChangeWaits24h() public {
        feed.queueQuantity(0, 2.5e18);
        uint256 effectiveAt = block.timestamp + 24 hours;
        (uint256 queuedQuantity, uint256 queuedAt) = feed.queued(0);
        assertEq(queuedQuantity, 2.5e18);
        assertEq(queuedAt, effectiveAt);

        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityNotDue.selector, effectiveAt));
        feed.applyQuantity(0);
        vm.warp(effectiveAt - 1);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityNotDue.selector, effectiveAt));
        feed.applyQuantity(0);

        vm.warp(effectiveAt);
        vm.expectEmit(true, false, false, true, address(feed));
        emit StockIndexFeed.QuantityApplied(0, 2.5e18);
        vm.prank(alice); // anyone may apply it once due
        feed.applyQuantity(0);
        (,, uint256 quantity) = feed.component(0);
        assertEq(quantity, 2.5e18);
        (queuedQuantity, queuedAt) = feed.queued(0);
        assertEq(queuedAt, 0);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.NoQueuedQuantity.selector, 0));
        feed.applyQuantity(0);

        // A change the guardian cancels cannot be applied.
        feed.queueQuantity(1, 1e18);
        vm.prank(guardian);
        feed.cancelQuantity(1);
        vm.warp(block.timestamp + 24 hours);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.NoQueuedQuantity.selector, 1));
        feed.applyQuantity(1);
        (,, quantity) = feed.component(1);
        assertEq(quantity, 0.5e18);
    }

    /// A quantity correction for a feed that moves to quoting half the price (a token migrated 2
    /// for 1; a split itself changes no quantity, the feed's price includes the multiplier): the
    /// owner queues double the quantity, the feed prints half the price, the guardian accepts the
    /// jump, and the index stays at 100 once the quantity applies.
    function test_aQuantityCorrectionKeepsThePriceContinuous() public {
        feed.queueQuantity(0, 0.5e18);
        vm.warp(block.timestamp + 24 hours);
        nvda.set(100e8);
        amd.set(AMD_PX);
        assertTrue(feed.jumped(0));
        feed.applyQuantity(0);
        _clear(0);
        (uint256 price,) = feed.latestPrice();
        assertEq(price, 100e18); // 0.5 * 100 + 0.5 * 100
        assertTrue(feed.isFresh());
    }

    function test_quantityQueueRules() public {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vm.prank(alice);
        feed.queueQuantity(0, 1e18);
        vm.expectRevert(StockIndexFeed.BadQuantity.selector);
        feed.queueQuantity(0, 0);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.UnknownComponent.selector, 2));
        feed.queueQuantity(2, 1e18);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.UnknownComponent.selector, 2));
        feed.applyQuantity(2);

        // Nothing queued: nothing to cancel. Only the owner or the guardian may.
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.NoQueuedQuantity.selector, 0));
        feed.cancelQuantity(0);
        feed.queueQuantity(0, 1e18);
        vm.expectRevert(StockIndexFeed.NotOwnerOrGuardian.selector);
        vm.prank(alice);
        feed.cancelQuantity(0);
        feed.cancelQuantity(0); // the owner may cancel its own change
        (, uint256 queuedAt) = feed.queued(0);
        assertEq(queuedAt, 0);

        // Queueing again replaces the pending change and restarts its 24 hours.
        feed.queueQuantity(0, 1e18);
        vm.warp(block.timestamp + 23 hours);
        feed.queueQuantity(0, 3e18);
        vm.warp(block.timestamp + 2 hours);
        vm.expectRevert(abi.encodeWithSelector(StockIndexFeed.QuantityNotDue.selector, block.timestamp + 22 hours));
        feed.applyQuantity(0);
    }

    // ---------------------------------------------------------------- roles and metadata

    function test_readyNeedsGuardianAndMethodology() public {
        StockIndexFeed fresh = _deploy(_two(address(nvda), address(amd)));
        assertFalse(fresh.ready());
        fresh.setGuardian(guardian);
        assertFalse(fresh.ready()); // no methodology yet
        fresh.setMethodology("https://docs.kyzen.network/silicon-markets/kdesign", keccak256("m"));
        assertTrue(fresh.ready());
        assertEq(fresh.guardian(), guardian);
        assertEq(fresh.methodologyHash(), keccak256("m"));
        assertEq(fresh.methodologyURI(), "https://docs.kyzen.network/silicon-markets/kdesign");
        assertEq(fresh.reporter(), address(0));
        (uint256 price, uint256 reportedAt, bytes32 sources, uint256 finalizesAt) = fresh.pendingPrice();
        assertEq(price, 0);
        assertEq(reportedAt, 0);
        assertEq(sources, bytes32(0));
        assertEq(finalizesAt, 0);

        // A methodology with no guardian is not ready either.
        StockIndexFeed other = _deploy(_two(address(nvda), address(amd)));
        other.setMethodology("u", keccak256("m"));
        assertFalse(other.ready());
    }

    function test_ownerOnlySetters() public {
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        feed.setGuardian(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        feed.setMethodology("u", keccak256("m"));
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- a broken feed never reverts

    function test_brokenFeedReadsAsStaleNeverReverts() public {
        BreakableFeed flaky = new BreakableFeed(8, 100e8);
        StockIndexFeed f = _deploy(_two(address(nvda), address(flaky)));
        assertTrue(f.isFresh());
        assertTrue(f.isFreshForLiquidation());
        assertFalse(f.jumped(1));

        BreakableFeed.Mode[5] memory modes = [
            BreakableFeed.Mode.Reverts,
            BreakableFeed.Mode.BurnsGas,
            BreakableFeed.Mode.ShortAnswer,
            BreakableFeed.Mode.Answer64,
            BreakableFeed.Mode.Answer159
        ];
        for (uint256 m; m < modes.length; ++m) {
            flaky.setMode(modes[m]);
            (uint256 price, uint256 updatedAt) = f.latestPrice();
            assertEq(price, 0);
            assertEq(updatedAt, 0);
            assertFalse(f.isFresh());
            assertFalse(f.isFreshForLiquidation());
            assertTrue(f.jumped(1));
            assertFalse(f.jumped(0));
        }

        // It reads again as soon as it works, and the deployment round is still accepted.
        flaky.setMode(BreakableFeed.Mode.Working);
        assertTrue(f.isFresh());
        (uint256 p,) = f.latestPrice();
        assertEq(p, 100e18);
    }

    /// An absurd answer reads as an unreadable price, not an overflow revert inside the vault.
    function test_absurdAnswersReadAsPriceZeroNeverRevert() public {
        // 18-decimal feeds that start at 1 wei: each quantity is 5e37.
        MockRoundFeed a = new MockRoundFeed(18, 1);
        MockRoundFeed b = new MockRoundFeed(18, 1);
        StockIndexFeed f = _deploy(_two(address(a), address(b)));

        // The largest answer: quantity * price (5e37 * 5.8e76) overflows 256 bits.
        a.set(type(int256).max);
        (uint256 price, uint256 updatedAt) = f.latestPrice();
        assertEq(price, 0);
        assertEq(updatedAt, 0);

        // A smaller one overflows quantity * price too (5e37 * 1.2e57 = 6e94, past 1.16e77).
        a.set(1.2e57);
        b.set(1.2e57);
        (price, updatedAt) = f.latestPrice();
        assertEq(price, 0);
        assertEq(updatedAt, 0);

        // A huge answer whose product still fits is read, not rejected: 5e37 * 1e30 / 1e18 = 5e49,
        // plus the other component's 5e37 * 1 / 1e18 = 5e19.
        a.set(1e30);
        b.set(1);
        (price, updatedAt) = f.latestPrice();
        assertEq(price, 5e49 + 5e19);
        assertEq(updatedAt, block.timestamp);
    }

    /// The jump check compares answers whose products with 10_000 would overflow.
    function test_jumpCheckHandlesHugeAnswers() public {
        MockRoundFeed a = new MockRoundFeed(18, 1);
        StockIndexFeed f = _deploy(_two(address(a), address(amd)));
        f.setGuardian(guardian);
        a.set(type(int256).max);
        assertTrue(f.jumped(0));
        vm.prank(guardian);
        f.clearJump(0, 2);
        a.set(type(int256).max - 1); // a move of one part in 5.8e76
        assertFalse(f.jumped(0));
        a.set(type(int256).max / 2); // -50%
        assertTrue(f.jumped(0));
    }

    /// An update time near the top of uint256 (or just ahead of the chain's clock) is unreadable,
    /// whatever the other components say: price zero, not fresh, no overflow in the age check.
    function test_futureUpdateTimeIsNotFreshNeverReverts() public {
        MockRoundFeed c = new MockRoundFeed(8, 100e8);
        vm.warp(block.timestamp + 1 hours);
        amd.set(AMD_PX); // the other component is newer than the deployment, older than the future
        StockIndexFeed g = _deploy(_two(address(c), address(amd)));
        assertTrue(g.isFresh());
        c.setUpdatedAt(type(uint256).max);
        (uint256 price, uint256 updatedAt) = g.latestPrice();
        assertEq(price, 0);
        assertEq(updatedAt, 0);
        assertFalse(g.isFresh());
        assertFalse(g.isFreshForLiquidation());
        c.setUpdatedAt(block.timestamp + 1);
        (price, updatedAt) = g.latestPrice();
        assertEq(price, 0);
        assertFalse(g.isFresh());
        assertFalse(g.isFreshForLiquidation());
        c.setUpdatedAt(block.timestamp);
        assertTrue(g.isFresh());
        assertTrue(g.isFreshForLiquidation());
    }

    /// One read serves the price and both freshness views: a component whose quantity * price
    /// overflows (even one the guardian has cleared) makes latestPrice (0, 0) and both views false.
    function test_overflowingComponentMakesBothViewsFalse() public {
        // 18-decimal feeds that start at 1 wei: each quantity is 5e37.
        MockRoundFeed a = new MockRoundFeed(18, 1);
        MockRoundFeed b = new MockRoundFeed(18, 1);
        StockIndexFeed f = _deploy(_two(address(a), address(b)));
        f.setGuardian(guardian);
        assertTrue(f.isFresh());
        assertTrue(f.isFreshForLiquidation());

        // The largest answer: quantity * price overflows 256 bits.
        a.set(type(int256).max);
        vm.prank(guardian);
        f.clearJump(0, 2);
        assertFalse(f.jumped(0));
        (uint256 price, uint256 updatedAt) = f.latestPrice();
        assertEq(price, 0);
        assertEq(updatedAt, 0);
        assertFalse(f.isFresh());
        assertFalse(f.isFreshForLiquidation());

        // Both components overflow quantity * price (5e37 * 1.2e57 = 6e94, past 1.16e77).
        a.set(1.2e57);
        b.set(1.2e57);
        vm.startPrank(guardian);
        f.clearJump(0, 3);
        f.clearJump(1, 2);
        vm.stopPrank();
        (price, updatedAt) = f.latestPrice();
        assertEq(price, 0);
        assertEq(updatedAt, 0);
        assertFalse(f.isFresh());
        assertFalse(f.isFreshForLiquidation());
    }

    /// The index rounds each component's value up, against the minter.
    function test_priceRoundsUpPerComponent() public {
        feed.queueQuantity(1, 3); // 3 wei of AMD per index unit
        vm.warp(block.timestamp + 24 hours);
        nvda.set(NVDA_PX);
        amd.set(10_000_000_001); // 100.00000001: three of it is 300.00000003 wei
        feed.applyQuantity(1);
        (uint256 price,) = feed.latestPrice();
        assertEq(price, 50e18 + 301); // NVDA 50e18 exactly, AMD ceil(300.00000003)
    }

    // ---------------------------------------------------------------- fuzz

    function testFuzz_priceIsSumOfQuantityTimesPrice(uint64 p0, uint64 p1) public {
        int256 a0 = int256(bound(p0, 1e8, 1e14));
        int256 a1 = int256(bound(p1, 1e8, 1e14));
        nvda.set(a0);
        amd.set(a1);
        _clear(0);
        _clear(1);
        (,, uint256 q0) = feed.component(0);
        (,, uint256 q1) = feed.component(1);
        // Each component's value rounds up (against the minter).
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 expected = _ceilDiv(q0 * uint256(a0) * 1e10, 1e18) + _ceilDiv(q1 * uint256(a1) * 1e10, 1e18);
        (uint256 price, uint256 updatedAt) = feed.latestPrice();
        assertEq(price, expected);
        assertEq(updatedAt, block.timestamp);
        assertTrue(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());
    }
}
