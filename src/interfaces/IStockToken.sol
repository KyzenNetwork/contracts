// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// Robinhood Stock Token issuer flags (SPEC 3.2a). paused() stops transfers;
/// oraclePaused() is set while a corporate action pauses the Chainlink feed.
interface IStockToken {
    function paused() external view returns (bool);
    function oraclePaused() external view returns (bool);
}
