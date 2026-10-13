// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// The Uniswap calls SiliconSwapAdapter makes, written by hand from v4-core and v3's SwapRouter02
// (each selector checked against the bytecode deployed on Robinhood Chain mainnet). Currencies are
// plain addresses (v4's Currency wraps an address), and a BalanceDelta is its underlying int256:
// amount0 in the upper 128 bits, amount1 in the lower.

/// A v4 pool: its two currencies in address order, the LP fee in hundredths of a bip, the tick
/// spacing and the hook. Same layout as v4-core's PoolKey, so a pool's id is
/// keccak256(abi.encode(key)).
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// v4-core's SwapParams: a negative amountSpecified is an exact input.
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

/// The v4 PoolManager.
interface IV4PoolManager {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

/// What the PoolManager calls back on the contract that unlocked it.
interface IV4UnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

/// Uniswap v3 SwapRouter02's single-pool exact input. It pulls the input from the caller by ERC-20
/// allowance and sends the output to `recipient`.
interface IV3SwapRouter02 {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
