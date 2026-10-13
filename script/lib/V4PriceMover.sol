// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IV4PoolManager, IV4UnlockCallback, PoolKey, SwapParams} from "../../src/silicon/interfaces/ISwapVenues.sol";

/// Moves a Uniswap v4 pool's price across a stretch with no liquidity, for free. SiliconPools.s.sol
/// deploys it when it re-places a Silicon bid: once the owner's old bid is removed the pool is empty,
/// and its price (the last trade's) must reach the index price again before a new USDG-only bid can
/// sit just below that price.
///
/// moveTo swaps one base unit of exact input with the target as the price limit. With no liquidity
/// in the way the swap crosses the empty ranges, exchanges nothing and stops at the limit. If any
/// liquidity lies in the way the swap would trade (at least the one unit's fee), and moveTo reverts
/// instead: it never pays or receives anything. It has no owner and no storage, holds nothing, and
/// can do nothing a swap through any router could not; anyone may call it.
contract V4PriceMover is IV4UnlockCallback {
    IV4PoolManager public immutable poolManager;

    error ZeroAddress();
    /// Only the PoolManager may call unlockCallback.
    error NotPoolManager();
    /// Liquidity lies between the pool's price and the target: the move would trade.
    error LiquidityInTheWay(int256 delta);

    constructor(IV4PoolManager poolManager_) {
        if (address(poolManager_) == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
    }

    /// Moves `key`'s price to `sqrtPriceLimitX96`: down when `zeroForOne`, up otherwise. Reverts
    /// (PoolManager's PriceLimitAlreadyExceeded) if the price is already past the target in that
    /// direction, and with LiquidityInTheWay if anything would trade.
    function moveTo(PoolKey calldata key, bool zeroForOne, uint160 sqrtPriceLimitX96) external {
        poolManager.unlock(abi.encode(key, zeroForOne, sqrtPriceLimitX96));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, uint160 limit) = abi.decode(data, (PoolKey, bool, uint160));
        int256 delta = poolManager.swap(
            key, SwapParams({zeroForOne: zeroForOne, amountSpecified: -1, sqrtPriceLimitX96: limit}), ""
        );
        if (delta != 0) revert LiquidityInTheWay(delta);
        return "";
    }
}
