// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// Chainlink price feed (SPEC 3.2a): equity feeds and ETH/USD, 8 decimals on Robinhood Chain.
interface IAggregatorV3 {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
    /// A past round, for the stock index feed's jump check. Reverts when the round has no data.
    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80);
}
