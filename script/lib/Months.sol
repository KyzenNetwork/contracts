// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// Calendar months in UTC, for the team stream's "6-month cliff, then linear over 12 months"
/// (SPEC 3.1). Adding months keeps the time of day and the day of the month, and clamps the
/// day to the last day of a shorter month: 31 August + 6 months is 28 or 29 February.
/// Day arithmetic follows Howard Hinnant's days_from_civil and civil_from_days.
library Months {
    uint256 private constant DAY = 86_400;

    function add(uint256 timestamp, uint256 months) internal pure returns (uint256) {
        (uint256 y, uint256 m, uint256 d) = _date(timestamp / DAY);
        uint256 total = y * 12 + (m - 1) + months;
        y = total / 12;
        m = total % 12 + 1;
        uint256 last = _daysInMonth(y, m);
        if (d > last) d = last;
        return _days(y, m, d) * DAY + timestamp % DAY;
    }

    function _daysInMonth(uint256 y, uint256 m) private pure returns (uint256) {
        if (m == 2) return (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28;
        if (m == 4 || m == 6 || m == 9 || m == 11) return 30;
        return 31;
    }

    /// Days since 1970-01-01 for a date on or after 1970-03-01.
    function _days(uint256 y, uint256 m, uint256 d) private pure returns (uint256) {
        if (m <= 2) y -= 1;
        uint256 era = y / 400;
        uint256 yoe = y - era * 400;
        uint256 mp = m > 2 ? m - 3 : m + 9;
        uint256 doy = (153 * mp + 2) / 5 + d - 1;
        uint256 doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
        return era * 146_097 + doe - 719_468;
    }

    function _date(uint256 z) private pure returns (uint256 y, uint256 m, uint256 d) {
        z += 719_468;
        uint256 era = z / 146_097;
        uint256 doe = z - era * 146_097;
        uint256 yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
        y = yoe + era * 400;
        uint256 doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
        uint256 mp = (5 * doy + 2) / 153;
        d = doy - (153 * mp + 2) / 5 + 1;
        m = mp < 10 ? mp + 3 : mp - 9;
        if (m <= 2) y += 1;
    }
}
