// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IV3SwapRouter02, IV4PoolManager, IV4UnlockCallback, PoolKey, SwapParams} from "./interfaces/ISwapVenues.sol";

/// @title Kyzen Network Silicon swap adapter (SPEC 3.5)
/// @notice A swap target for SiliconFeeRouter.convert. It sells the router's synth or USDG for WETH
/// and sends the WETH to the caller, which is the router. The synths trade only in their Uniswap v4
/// pools against USDG, and Uniswap's v4 routers pull a caller's tokens only through Permit2, while
/// the fee router only approves its target. This adapter pulls by plain ERC-20 allowance.
///
/// Two routes, chosen by the calldata the keeper encodes:
///   sellSynth(key, amountIn, v3Fee): the synth to USDG in its v4 pool `key` (no hook; one currency
///     is USDG), then the USDG to WETH in the v3 USDG/WETH pool with fee `v3Fee`;
///   sellUsdg(amountIn, v3Fee): USDG to WETH in that v3 pool.
/// Either pulls exactly `amountIn` from the caller and sends all the WETH to the caller. Any input
/// a pool does not take (a pool that runs out of liquidity) goes back to the caller in the same
/// call.
///
/// No swap has a price limit. The router checks the keeper's minOut on the WETH that arrived,
/// after the call, and reverts the whole conversion below it, so minOut bounds the route end to end.
/// The keeper is trusted for the route as well as for minOut: it picks the v4 pool key and the v3
/// fee, and a route through a pool of its choosing is bounded only by its own minOut.
///
/// Why a caller cannot take anything:
/// - The adapter has no owner and no storage, and holds nothing between calls: what it pulls, it
///   either swaps or returns within the call.
/// - It moves only the caller's own tokens, by the allowance the caller gave it, and pays the output
///   to the caller.
/// - Every amount it spends or returns is the amount it pulled or the amount a pool paid it in the
///   call, never its balance. A token sent to it directly stays where it is: no call can sweep it,
///   and there is no owner to recover it.
/// - Its one approval, of USDG to SwapRouter02, is for exactly the amount sold and is reset to zero
///   if any of it is left.
/// - unlockCallback runs only for the PoolManager, which calls back only the contract that unlocked
///   it: this adapter, inside sellSynth, with data the adapter wrote.
/// - A hooked pool is refused, so no third-party code runs inside the swap except the tokens
///   themselves. A caller who names its own token as the "synth" can only sell that token in a pool
///   it chose, for its own benefit.
contract SiliconSwapAdapter is IV4UnlockCallback {
    using SafeERC20 for IERC20;

    /// v4-core's TickMath bounds plus one: a swap with these limits has no price limit.
    uint160 internal constant MIN_SQRT_PRICE_PLUS_ONE = 4295128740;
    uint160 internal constant MAX_SQRT_PRICE_MINUS_ONE = 1461446703485210103287273052203988822378723970341;

    /// The Uniswap v4 PoolManager, where the synths trade against USDG.
    IV4PoolManager public immutable poolManager;
    /// Uniswap v3 SwapRouter02, which sells USDG for WETH.
    IV3SwapRouter02 public immutable swapRouter;
    /// WETH, what the router counts as received.
    address public immutable weth;
    /// USDG, the synths' quote currency.
    address public immutable usdg;

    /// An address given to the constructor is zero, or two of them are the same.
    error BadAddress();
    /// The amount is zero. Zero is never passed on: SwapRouter02 reads an amountIn of 0 as
    /// CONTRACT_BALANCE, "swap whatever the router itself holds".
    error BadAmount();
    /// The synth amount does not fit a v4 balance delta (int128).
    error AmountTooLarge(uint256 amount, uint256 maximum);
    /// The pool has a hook, has no USDG side, or its other side is not a token that could be a
    /// synth.
    error BadPool();
    /// Only the PoolManager may call unlockCallback.
    error NotPoolManager();
    /// The synth sale returned no USDG.
    error NoUsdgOut();

    constructor(IV4PoolManager poolManager_, IV3SwapRouter02 swapRouter_, address weth_, address usdg_) {
        if (
            address(poolManager_) == address(0) || address(swapRouter_) == address(0) || weth_ == address(0)
                || usdg_ == address(0) || weth_ == usdg_
        ) revert BadAddress();
        poolManager = poolManager_;
        swapRouter = swapRouter_;
        weth = weth_;
        usdg = usdg_;
    }

    /// Pulls `amountIn` of the synth in `key` from the caller and sells it for USDG in that v4 pool,
    /// then sells the USDG for WETH in the v3 USDG/WETH pool with fee `v3Fee`. The WETH, and any
    /// synth or USDG a pool did not take, go to the caller. Returns the WETH sent.
    function sellSynth(PoolKey calldata key, uint256 amountIn, uint24 v3Fee) external returns (uint256 wethOut) {
        // Zero would reach SwapRouter02 as its CONTRACT_BALANCE sentinel (0 = the router's own
        // balance) once the v4 leg returned nothing; it is refused here and by NoUsdgOut below.
        if (amountIn == 0) revert BadAmount();
        // A v4 swap's deltas are int128: a larger amount could never settle.
        if (amountIn > uint256(uint128(type(int128).max))) {
            revert AmountTooLarge(amountIn, uint256(uint128(type(int128).max)));
        }
        if (key.hooks != address(0)) revert BadPool();
        bool synthIsCurrency0;
        address synth;
        if (key.currency1 == usdg) {
            (synthIsCurrency0, synth) = (true, key.currency0);
        } else if (key.currency0 == usdg) {
            (synthIsCurrency0, synth) = (false, key.currency1);
        } else {
            revert BadPool();
        }
        if (synth == address(0) || synth == usdg || synth == weth) revert BadPool();

        IERC20(synth).safeTransferFrom(msg.sender, address(this), amountIn);
        (uint256 paid, uint256 usdgOut) =
            abi.decode(poolManager.unlock(abi.encode(key, synthIsCurrency0, amountIn)), (uint256, uint256));
        if (paid < amountIn) IERC20(synth).safeTransfer(msg.sender, amountIn - paid);
        // Never hand SwapRouter02 an amountIn of 0: it would sell its own balance (CONTRACT_BALANCE).
        if (usdgOut == 0) revert NoUsdgOut();
        wethOut = _sellUsdg(usdgOut, v3Fee);
    }

    /// Pulls `amountIn` USDG from the caller and sells it for WETH in the v3 USDG/WETH pool with fee
    /// `v3Fee`. The WETH, and any USDG the pool did not take, go to the caller. Returns the WETH sent.
    function sellUsdg(uint256 amountIn, uint24 v3Fee) external returns (uint256 wethOut) {
        // Never hand SwapRouter02 an amountIn of 0: it would sell its own balance (CONTRACT_BALANCE).
        if (amountIn == 0) revert BadAmount();
        IERC20(usdg).safeTransferFrom(msg.sender, address(this), amountIn);
        wethOut = _sellUsdg(amountIn, v3Fee);
    }

    /// The PoolManager's callback inside sellSynth: sells exactly `amountIn` of the synth (or what
    /// the pool takes before its price runs out of liquidity), pays the PoolManager what the swap
    /// took, and takes the USDG to this adapter. Returns (synth paid, USDG received).
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        (PoolKey memory key, bool zeroForOne, uint256 amountIn) = abi.decode(data, (PoolKey, bool, uint256));
        int256 delta = poolManager.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_PLUS_ONE : MAX_SQRT_PRICE_MINUS_ONE
            }),
            ""
        );
        // BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower. The input is owed
        // (negative), the output is due (positive).
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        (int128 owed, int128 due) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        (address synth, address quote) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        uint256 paid = owed < 0 ? uint256(uint128(-owed)) : 0;
        uint256 received = due > 0 ? uint256(uint128(due)) : 0;
        poolManager.sync(synth);
        if (paid != 0) IERC20(synth).safeTransfer(address(poolManager), paid);
        poolManager.settle();
        if (received != 0) poolManager.take(quote, address(this), received);
        return abi.encode(paid, received);
    }

    /// Sells `amount` USDG held for this call for WETH to the caller, returns any USDG the pool did
    /// not take to the caller, and leaves no approval behind. `amount` is never zero (BadAmount,
    /// NoUsdgOut), so SwapRouter02 never reads it as CONTRACT_BALANCE.
    function _sellUsdg(uint256 amount, uint24 v3Fee) private returns (uint256 wethOut) {
        IERC20 token = IERC20(usdg);
        uint256 before = token.balanceOf(address(this));
        token.forceApprove(address(swapRouter), amount);
        wethOut = swapRouter.exactInputSingle(
            IV3SwapRouter02.ExactInputSingleParams({
                tokenIn: usdg,
                tokenOut: weth,
                fee: v3Fee,
                recipient: msg.sender,
                amountIn: amount,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            })
        );
        uint256 spent = before - token.balanceOf(address(this));
        if (token.allowance(address(this), address(swapRouter)) != 0) token.forceApprove(address(swapRouter), 0);
        if (spent < amount) token.safeTransfer(msg.sender, amount - spent);
    }
}
