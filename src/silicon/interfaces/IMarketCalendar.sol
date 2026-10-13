// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// When Silicon stock-index markets may mint (SPEC 3.5).
interface IMarketCalendar {
    /// True inside the minting window at `timestamp`.
    function isMintWindow(uint256 timestamp) external view returns (bool);
}
