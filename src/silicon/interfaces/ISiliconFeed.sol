// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// What SiliconVault reads from a market's price feed.
interface ISiliconFeed {
    /// The last final price in USD (18 decimals) and when it was reported; (0, 0) before the first.
    function latestPrice() external view returns (uint256 price, uint256 updatedAt);
    /// True while the price is fresh enough to mint against (each feed states its own rule).
    function isFresh() external view returns (bool);
    /// True while every price is fresh enough to start a liquidation.
    function isFreshForLiquidation() external view returns (bool);
    /// The price still inside its dispute window, if any (all zero when none is).
    function pendingPrice()
        external
        view
        returns (uint256 price, uint256 reportedAt, bytes32 sourcesHash, uint256 finalizesAt);
    /// The address that posts prices (zero: none).
    function reporter() external view returns (address);
    /// The address that may reject a posted price within its dispute window (zero: none).
    function guardian() external view returns (address);
    /// Hash of the published methodology (zero until published).
    function methodologyHash() external view returns (bytes32);
    /// True once the feed may back an open market.
    function ready() external view returns (bool);
    /// Records the rounds checked since the last call; the vault calls it before reading freshness.
    /// Never reverts.
    function sync() external;
}
