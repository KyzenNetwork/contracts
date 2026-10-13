// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// What Staking reads from the Reserve for the chip-equity payout: the swap-target
/// allowlist and the Chainlink feeds, so both contracts apply one set of rules.
interface IReserveView {
    function assetInfo(address token)
        external
        view
        returns (address feed, uint8 feedDecimals, uint8 stage, uint64 lastTradeAt, bool listed);
    /// True only for a live target the one swap-target rule allows: never the zero address,
    /// $KYZN, WETH, the $KYZN/WETH pair, the Reserve, Staking, or a listed or pending asset.
    function isTargetAllowed(address target) external view returns (bool);
    function ethUsdFeed() external view returns (address);
    function ethUsdDecimals() external view returns (uint8);
}
