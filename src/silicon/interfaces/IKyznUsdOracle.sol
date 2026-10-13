// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// What SiliconVault reads for $KYZN collateral.
interface IKyznUsdOracle {
    /// Records a pool observation when one is due; returns whether it recorded one.
    function update() external returns (bool recorded);
    /// USD per $KYZN (18 decimals). Reverts when no average or no fresh ETH/USD answer is available.
    function price() external view returns (uint256 usdPerKyzn);
}
