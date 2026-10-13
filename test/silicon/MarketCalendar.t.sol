// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {MarketCalendar} from "../../src/silicon/MarketCalendar.sol";

contract MarketCalendarTest is Test {
    MarketCalendar cal;
    // Monday 2026-10-05 00:00 UTC (day 20731).
    uint256 constant MON = 1_791_158_400;
    // Monday 2027-01-04 00:00 UTC (day 20822), in US winter time.
    uint256 constant WINTER_MON = 1_799_020_800;

    function setUp() public {
        cal = new MarketCalendar(address(this));
        vm.warp(MON - 3 days);
    }

    function test_windowIsWeekdays1430To2000Utc() public view {
        assertFalse(cal.isMintWindow(MON + 14 hours + 29 minutes + 59));
        assertTrue(cal.isMintWindow(MON + 14 hours + 30 minutes));
        assertTrue(cal.isMintWindow(MON + 19 hours + 59 minutes + 59));
        assertFalse(cal.isMintWindow(MON + 20 hours));
        assertTrue(cal.isMintWindow(MON + 4 days + 15 hours)); // Friday
        assertFalse(cal.isMintWindow(MON + 5 days + 15 hours)); // Saturday
        assertFalse(cal.isMintWindow(MON - 1 days + 15 hours)); // Sunday
    }

    function test_dayNumbersAreMondays() public pure {
        // Weekday = (day + 4) % 7 with 0 = Sunday, so a Monday is 1.
        assertEq(MON / 1 days, 20731);
        assertEq((MON / 1 days + 4) % 7, 1);
        assertEq(WINTER_MON / 1 days, 20822);
        assertEq((WINTER_MON / 1 days + 4) % 7, 1);
    }

    function test_windowHoldsInWinterAndOnFriday() public view {
        // The same 14:30 to 20:00 UTC window in US winter time (Monday 2027-01-04).
        assertFalse(cal.isMintWindow(WINTER_MON + 14 hours + 29 minutes + 59));
        assertTrue(cal.isMintWindow(WINTER_MON + 14 hours + 30 minutes));
        assertTrue(cal.isMintWindow(WINTER_MON + 19 hours + 59 minutes + 59));
        assertFalse(cal.isMintWindow(WINTER_MON + 20 hours));
        // Friday boundary: open at 19:59:59, closed at 20:00:00.
        assertTrue(cal.isMintWindow(MON + 4 days + 19 hours + 59 minutes + 59));
        assertFalse(cal.isMintWindow(MON + 4 days + 20 hours));
    }

    function test_holidayClosesAndEarlyCloseEndsAt1700() public {
        uint256[] memory d = new uint256[](1);
        d[0] = (MON + 1 days) / 1 days; // Tuesday
        vm.expectEmit(address(cal));
        emit MarketCalendar.DaySet(d[0], MarketCalendar.DayKind.Closed);
        cal.setDays(d, MarketCalendar.DayKind.Closed);
        assertFalse(cal.isMintWindow(MON + 1 days + 15 hours));
        d[0] = (MON + 2 days) / 1 days; // Wednesday
        vm.expectEmit(address(cal));
        emit MarketCalendar.DaySet(d[0], MarketCalendar.DayKind.EarlyClose);
        cal.setDays(d, MarketCalendar.DayKind.EarlyClose);
        assertTrue(cal.isMintWindow(MON + 2 days + 16 hours + 59 minutes));
        assertFalse(cal.isMintWindow(MON + 2 days + 17 hours));
    }

    function test_onlyOwnerAndReopeningNeedsADay() public {
        uint256[] memory d = new uint256[](1);
        d[0] = MON / 1 days;
        vm.prank(address(0xBEEF));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(0xBEEF)));
        cal.setDays(d, MarketCalendar.DayKind.Closed);
        cal.setDays(d, MarketCalendar.DayKind.Closed);
        // Making a day regular again relaxes the window: only for a day that starts 24 hours or more from now.
        vm.warp(MON - 23 hours);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.ReopenTooSoon.selector, MON / 1 days));
        cal.setDays(d, MarketCalendar.DayKind.Regular);
        vm.warp(MON - 24 hours);
        cal.setDays(d, MarketCalendar.DayKind.Regular);
        assertTrue(cal.isMintWindow(MON + 15 hours));
    }

    /// Each day of a batch is marked and announced, in order.
    function test_setDaysEmitsDaySetForEachDay() public {
        uint256[] memory d = new uint256[](3);
        d[0] = (MON + 1 days) / 1 days;
        d[1] = (MON + 3 days) / 1 days;
        d[2] = (MON + 4 days) / 1 days;
        for (uint256 i; i < 3; ++i) {
            vm.expectEmit(address(cal));
            emit MarketCalendar.DaySet(d[i], MarketCalendar.DayKind.Closed);
        }
        cal.setDays(d, MarketCalendar.DayKind.Closed);
        for (uint256 i; i < 3; ++i) {
            assertEq(uint256(cal.dayKind(d[i])), uint256(MarketCalendar.DayKind.Closed));
        }
    }

    function test_closedToEarlyCloseNeedsADay() public {
        uint256 day = (MON + 1 days) / 1 days; // Tuesday
        uint256[] memory d = new uint256[](1);
        d[0] = day;
        cal.setDays(d, MarketCalendar.DayKind.Closed);
        // Opening an early-close window on a closed day relaxes it: 23 hours ahead is too soon.
        vm.warp(MON + 1 days - 23 hours);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.ReopenTooSoon.selector, day));
        cal.setDays(d, MarketCalendar.DayKind.EarlyClose);
        assertEq(uint256(cal.dayKind(day)), uint256(MarketCalendar.DayKind.Closed));
        assertFalse(cal.isMintWindow(MON + 1 days + 15 hours));
        // 24 hours ahead is enough.
        vm.warp(MON + 1 days - 24 hours);
        cal.setDays(d, MarketCalendar.DayKind.EarlyClose);
        assertTrue(cal.isMintWindow(MON + 1 days + 16 hours + 59 minutes + 59));
        assertFalse(cal.isMintWindow(MON + 1 days + 17 hours));
    }

    function test_earlyCloseToRegularNeedsADay() public {
        uint256 day = (MON + 2 days) / 1 days; // Wednesday
        uint256[] memory d = new uint256[](1);
        d[0] = day;
        cal.setDays(d, MarketCalendar.DayKind.EarlyClose);
        vm.warp(MON + 2 days - 23 hours);
        vm.expectRevert(abi.encodeWithSelector(MarketCalendar.ReopenTooSoon.selector, day));
        cal.setDays(d, MarketCalendar.DayKind.Regular);
        assertFalse(cal.isMintWindow(MON + 2 days + 17 hours));
        vm.warp(MON + 2 days - 24 hours);
        cal.setDays(d, MarketCalendar.DayKind.Regular);
        assertTrue(cal.isMintWindow(MON + 2 days + 17 hours));
    }

    function test_unchangedKindNeverReverts() public {
        // A past day marked Regular again changes nothing, so it needs no notice.
        uint256[] memory d = new uint256[](1);
        d[0] = MON / 1 days;
        vm.warp(MON + 3 days);
        cal.setDays(d, MarketCalendar.DayKind.Regular);
        assertEq(uint256(cal.dayKind(d[0])), uint256(MarketCalendar.DayKind.Regular));
        // The same holds for an unchanged EarlyClose or Closed day.
        cal.setDays(d, MarketCalendar.DayKind.EarlyClose);
        cal.setDays(d, MarketCalendar.DayKind.EarlyClose);
        cal.setDays(d, MarketCalendar.DayKind.Closed);
        cal.setDays(d, MarketCalendar.DayKind.Closed);
        assertEq(uint256(cal.dayKind(d[0])), uint256(MarketCalendar.DayKind.Closed));
    }

    function test_restrictingTakesEffectAtOnce() public {
        uint256[] memory d = new uint256[](1);
        d[0] = (MON + 2 days) / 1 days; // Wednesday
        // Mid-session, with the day already under way: early close ends the window now.
        vm.warp(MON + 2 days + 16 hours + 30 minutes);
        assertTrue(cal.isMintWindow(block.timestamp));
        cal.setDays(d, MarketCalendar.DayKind.EarlyClose);
        assertTrue(cal.isMintWindow(MON + 2 days + 16 hours + 59 minutes + 59));
        assertFalse(cal.isMintWindow(MON + 2 days + 17 hours));
        // EarlyClose to Closed, still at once.
        cal.setDays(d, MarketCalendar.DayKind.Closed);
        assertFalse(cal.isMintWindow(block.timestamp));
        assertFalse(cal.isMintWindow(MON + 2 days + 15 hours));
    }
}
