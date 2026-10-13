// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IMarketCalendar} from "./interfaces/IMarketCalendar.sol";

/// @title Kyzen Network market calendar (SPEC 3.5)
/// @notice The minting window of the Silicon stock indices: Monday to Friday, 14:30 to 20:00 UTC,
/// inside the regular US session in both summer and winter. The owner marks exchange holidays
/// (closed) and early-close days (the window ends at 17:00 UTC). From most to least restrictive a
/// day is Closed, EarlyClose, Regular. A change that restricts a day more, or leaves it as it is,
/// takes effect at once. A change that relaxes a day (Closed to EarlyClose, Closed to Regular,
/// EarlyClose to Regular) is accepted only for a day that starts at least 24 hours from now.
contract MarketCalendar is Ownable2Step, IMarketCalendar {
    /// How a UTC day trades: the regular window, no window, or a window that ends early.
    enum DayKind {
        Regular,
        Closed,
        EarlyClose
    }

    /// Seconds into a UTC day when the window opens (14:30).
    uint256 public constant OPEN = 14 hours + 30 minutes;
    /// Seconds into a UTC day when the window closes (20:00).
    uint256 public constant CLOSE = 20 hours;
    /// Seconds into a UTC day when the window closes on an early-close day (17:00).
    uint256 public constant EARLY_CLOSE = 17 hours;
    /// Seconds ahead a day must start for the owner to relax it (Closed to EarlyClose or Regular,
    /// EarlyClose to Regular).
    uint256 public constant REOPEN_NOTICE = 24 hours;

    /// The kind of each UTC day (timestamp / 1 days); Regular unless marked.
    mapping(uint256 day => DayKind) public dayKind;

    /// The owner marked `day`.
    event DaySet(uint256 indexed day, DayKind kind);

    /// A day cannot be relaxed (Closed to EarlyClose or Regular, EarlyClose to Regular) unless it
    /// starts at least 24 hours from now.
    error ReopenTooSoon(uint256 day);

    /// `owner_` marks the days; every day starts Regular.
    constructor(address owner_) Ownable(owner_) {}

    // ---------------------------------------------------------------- owner

    /// Marks each of `days_` (UTC day numbers) as `kind`. A day that `kind` leaves as restricted as
    /// it was, or restricts more, changes at once. A day that `kind` relaxes reverts with
    /// ReopenTooSoon unless it starts at least REOPEN_NOTICE from now.
    function setDays(uint256[] calldata days_, DayKind kind) external onlyOwner {
        uint256 n = days_.length;
        uint256 newRank = _rank(kind);
        for (uint256 i; i < n; ++i) {
            uint256 day = days_[i];
            if (newRank < _rank(dayKind[day]) && day * 1 days < block.timestamp + REOPEN_NOTICE) {
                revert ReopenTooSoon(day);
            }
            dayKind[day] = kind;
            emit DaySet(day, kind);
        }
    }

    // ---------------------------------------------------------------- views

    /// @inheritdoc IMarketCalendar
    function isMintWindow(uint256 timestamp) external view returns (bool) {
        uint256 day = timestamp / 1 days;
        uint256 weekday = (day + 4) % 7; // 0 = Sunday; 1 January 1970 was a Thursday
        if (weekday == 0 || weekday == 6) return false;
        DayKind kind = dayKind[day];
        if (kind == DayKind.Closed) return false;
        uint256 second = timestamp % 1 days;
        uint256 close = kind == DayKind.EarlyClose ? EARLY_CLOSE : CLOSE;
        return second >= OPEN && second < close;
    }

    // ---------------------------------------------------------------- internals

    /// How restrictive a kind is: Regular 0, EarlyClose 1, Closed 2.
    function _rank(DayKind kind) private pure returns (uint256) {
        if (kind == DayKind.Closed) return 2;
        if (kind == DayKind.EarlyClose) return 1;
        return 0;
    }
}
