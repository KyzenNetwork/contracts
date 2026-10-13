// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// The Uniswap v4 calls the Silicon pool script and its fork test make, written by hand from
// v4-core and v4-periphery (each selector checked against the deployed bytecode on Robinhood Chain
// mainnet). PoolKey, SwapParams and the PoolManager's interface are SiliconSwapAdapter's
// (src/silicon/interfaces/ISwapVenues.sol), imported here so the two share one type.

import {IV4PoolManager, IV4UnlockCallback, PoolKey, SwapParams} from "../../src/silicon/interfaces/ISwapVenues.sol";

/// v4-periphery's IV4Quoter.QuoteExactSingleParams.
struct QuoteExactSingleParams {
    PoolKey poolKey;
    bool zeroForOne;
    uint128 exactAmount;
    bytes hookData;
}

/// The PositionManager (v4-periphery): position NFTs, actions run through modifyLiquidities, and
/// multicall, which runs initializePool and modifyLiquidities in one transaction. It pulls tokens
/// through Permit2 only.
interface IV4PositionManager {
    function poolManager() external view returns (address);
    function permit2() external view returns (address);
    function nextTokenId() external view returns (uint256);
    function ownerOf(uint256 tokenId) external view returns (address);
    function getPositionLiquidity(uint256 tokenId) external view returns (uint128 liquidity);
    /// The position's pool, and its PositionInfo (packed: pool id, ticks, subscriber flag).
    function getPoolAndPositionInfo(uint256 tokenId) external view returns (PoolKey memory poolKey, uint256 info);
    /// The pool's tick, or type(int24).max when the PoolManager refused (already initialised).
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

/// StateView (v4-periphery lens): a pool's state by id.
interface IV4StateView {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

/// V4Quoter (v4-periphery lens). Not a view: it simulates the swap and reverts internally.
interface IV4Quoter {
    function quoteExactInputSingle(QuoteExactSingleParams memory params)
        external
        returns (uint256 amountOut, uint256 gasEstimate);
}

/// Permit2's allowance transfer: the ERC-20 is approved to Permit2, and Permit2 approves the
/// spender for an amount until an expiry.
interface IPermit2 {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external
        view
        returns (uint160 amount, uint48 expiration, uint48 nonce);
}
