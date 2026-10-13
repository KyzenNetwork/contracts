// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Months} from "../script/lib/Months.sol";

contract MonthsTest is Test {
    function test_adds_calendar_months_and_keeps_the_time_of_day() public pure {
        // 2026-10-01 09:30:15 UTC + 6 months = 2027-04-01 09:30:15 UTC
        assertEq(Months.add(1_790_847_015, 6), 1_806_571_815);
        // + 18 months = 2028-04-01 09:30:15 UTC
        assertEq(Months.add(1_790_847_015, 18), 1_838_194_215);
    }

    function test_clamps_to_the_end_of_a_shorter_month() public pure {
        // 2026-01-31 00:00 UTC + 1 month = 2026-02-28
        assertEq(Months.add(1_769_817_600, 1), 1_772_236_800);
        // 2027-08-31 00:00 UTC + 6 months = 2028-02-29 (leap year)
        assertEq(Months.add(1_819_670_400, 6), 1_835_395_200);
        // 2026-12-31 00:00 UTC + 2 months = 2027-02-28 (year rollover)
        assertEq(Months.add(1_798_675_200, 2), 1_803_772_800);
    }

    function test_zero_months_is_identity(uint32 t) public pure {
        uint256 ts = uint256(t) + 5_097_600; // on or after 1970-03-01
        assertEq(Months.add(ts, 0), ts);
    }

    function testFuzz_adding_twelve_months_moves_one_year(uint32 t) public pure {
        uint256 ts = uint256(t) + 5_097_600;
        uint256 next = Months.add(ts, 12);
        uint256 dayDiff = (next - ts) / 1 days;
        // 365 or 366 days, or 364/365 when 29 February clamps to 28 February
        assertTrue(dayDiff >= 364 && dayDiff <= 366);
        assertEq(next % 1 days, ts % 1 days);
    }
}
