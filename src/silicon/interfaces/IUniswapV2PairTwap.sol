// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// The Uniswap v2 pair calls KyznUsdOracle reads: token order, reserves and cumulative prices.
interface IUniswapV2PairTwap {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
}
