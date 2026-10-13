// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// Uniswap v4 price, tick and liquidity math for seeding a pool, with the pool's own rounding.
/// getSqrtPriceAtTick, the amount deltas and the liquidity for amounts follow v4-core's TickMath
/// and SqrtPriceMath and v4-periphery's LiquidityAmounts (MIT), written without assembly;
/// getTickAtSqrtPrice keeps TickMath's definition (the greatest tick whose price is at or below
/// the given one) and finds it by bisection over getSqrtPriceAtTick.
library V4PoolMath {
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = 887272;
    /// getSqrtPriceAtTick(MIN_TICK) and getSqrtPriceAtTick(MAX_TICK).
    uint160 internal constant MIN_SQRT_PRICE = 4295128739;
    uint160 internal constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    uint256 internal constant Q96 = 1 << 96;
    uint256 internal constant Q192 = 1 << 192;

    error InvalidTick(int24 tick);
    error InvalidSqrtPrice(uint256 sqrtPriceX96);
    error LiquidityOverflow(uint256 liquidity);

    /// sqrt(1.0001^tick) as a Q64.96 number, rounded up (TickMath.getSqrtPriceAtTick).
    function getSqrtPriceAtTick(int24 tick) internal pure returns (uint160) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        if (absTick > uint256(int256(MAX_TICK))) revert InvalidTick(tick);
        unchecked {
            uint256 price = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 1 << 128;
            if (absTick & 0x2 != 0) price = (price * 0xfff97272373d413259a46990580e213a) >> 128;
            if (absTick & 0x4 != 0) price = (price * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
            if (absTick & 0x8 != 0) price = (price * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
            if (absTick & 0x10 != 0) price = (price * 0xffcb9843d60f6159c9db58835c926644) >> 128;
            if (absTick & 0x20 != 0) price = (price * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
            if (absTick & 0x40 != 0) price = (price * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
            if (absTick & 0x80 != 0) price = (price * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
            if (absTick & 0x100 != 0) price = (price * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
            if (absTick & 0x200 != 0) price = (price * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
            if (absTick & 0x400 != 0) price = (price * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
            if (absTick & 0x800 != 0) price = (price * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
            if (absTick & 0x1000 != 0) price = (price * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
            if (absTick & 0x2000 != 0) price = (price * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
            if (absTick & 0x4000 != 0) price = (price * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
            if (absTick & 0x8000 != 0) price = (price * 0x31be135f97d08fd981231505542fcfa6) >> 128;
            if (absTick & 0x10000 != 0) price = (price * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
            if (absTick & 0x20000 != 0) price = (price * 0x5d6af8dedb81196699c329225ee604) >> 128;
            if (absTick & 0x40000 != 0) price = (price * 0x2216e584f5fa1ea926041bedfe98) >> 128;
            if (absTick & 0x80000 != 0) price = (price * 0x48a170391f7dc42444e8fa2) >> 128;
            if (tick > 0) price = type(uint256).max / price;
            // Q128.128 to Q64.96, rounding up.
            return uint160((price >> 32) + (price & 0xffffffff == 0 ? 0 : 1));
        }
    }

    /// The greatest tick whose sqrt price is at or below `sqrtPriceX96` (TickMath.getTickAtSqrtPrice):
    /// the tick a pool initialised at that price reports.
    function getTickAtSqrtPrice(uint160 sqrtPriceX96) internal pure returns (int24) {
        if (sqrtPriceX96 < MIN_SQRT_PRICE || sqrtPriceX96 >= MAX_SQRT_PRICE) revert InvalidSqrtPrice(sqrtPriceX96);
        int256 lo = MIN_TICK; // getSqrtPriceAtTick(lo) <= sqrtPriceX96 throughout
        int256 hi = int256(MAX_TICK) - 1; // the answer is at most hi throughout
        while (lo < hi) {
            int256 mid = lo + (hi - lo + 1) / 2;
            if (getSqrtPriceAtTick(int24(mid)) <= sqrtPriceX96) lo = mid;
            else hi = mid - 1;
        }
        return int24(lo);
    }

    /// The lowest and highest ticks a position with this spacing may use.
    function minUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (MIN_TICK / tickSpacing) * tickSpacing;
    }

    function maxUsableTick(int24 tickSpacing) internal pure returns (int24) {
        return (MAX_TICK / tickSpacing) * tickSpacing;
    }

    /// `tick` rounded down (toward the lower price) to a multiple of `tickSpacing`.
    function floorToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 r = (tick / tickSpacing) * tickSpacing;
        return r > tick ? r - tickSpacing : r;
    }

    /// `tick` rounded up (toward the higher price) to a multiple of `tickSpacing`.
    function ceilToSpacing(int24 tick, int24 tickSpacing) internal pure returns (int24) {
        int24 r = (tick / tickSpacing) * tickSpacing;
        return r < tick ? r + tickSpacing : r;
    }

    // ---------------------------------------------------------------- the synth's USD price

    /// The pool price of a synth worth `usdPrice` (USD per whole synth, 18 decimals) with USDG at
    /// $1.00, as a Q64.96 square root of currency1 per currency0 in base units, rounded down.
    /// `scale` is 10^(18 + synth decimals - USDG decimals): one USDG base unit per synth base unit
    /// is a USD price of `scale`.
    function sqrtPriceForUsd(uint256 usdPrice, bool synthIsCurrency0, uint256 scale) internal pure returns (uint160) {
        uint256 ratioX192 = synthIsCurrency0 ? Math.mulDiv(usdPrice, Q192, scale) : Math.mulDiv(scale, Q192, usdPrice);
        uint256 root = Math.sqrt(ratioX192);
        if (root < MIN_SQRT_PRICE || root >= MAX_SQRT_PRICE) revert InvalidSqrtPrice(root);
        return uint160(root);
    }

    /// The synth's USD price (18 decimals) at a pool price, rounded down: the inverse of
    /// sqrtPriceForUsd.
    function usdForSqrtPrice(uint160 sqrtPriceX96, bool synthIsCurrency0, uint256 scale)
        internal
        pure
        returns (uint256)
    {
        uint256 ratioX128 = Math.mulDiv(sqrtPriceX96, sqrtPriceX96, 1 << 64);
        return synthIsCurrency0 ? Math.mulDiv(ratioX128, scale, 1 << 128) : Math.mulDiv(scale, 1 << 128, ratioX128);
    }

    // ---------------------------------------------------------------- liquidity and amounts

    /// The most liquidity `amount0` and `amount1` pay for at `sqrtPriceX96` in the range
    /// [sqrtPriceAX96, sqrtPriceBX96] (LiquidityAmounts.getLiquidityForAmounts).
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128) {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        uint256 liquidity;
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = _liquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 < sqrtPriceBX96) {
            liquidity = Math.min(
                _liquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0),
                _liquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1)
            );
        } else {
            liquidity = _liquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
        return toUint128(liquidity);
    }

    /// What adding `liquidity` in [tickLower, tickUpper) takes from the owner while the pool is at
    /// `sqrtPriceX96` and `tick`: Pool.modifyLiquidity's amounts, rounded up.
    function getAmountsForLiquidity(
        uint160 sqrtPriceX96,
        int24 tick,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity
    ) internal pure returns (uint256 amount0, uint256 amount1) {
        uint160 lower = getSqrtPriceAtTick(tickLower);
        uint160 upper = getSqrtPriceAtTick(tickUpper);
        if (tick < tickLower) {
            amount0 = getAmount0Delta(lower, upper, liquidity);
        } else if (tick < tickUpper) {
            amount0 = getAmount0Delta(sqrtPriceX96, upper, liquidity);
            amount1 = getAmount1Delta(lower, sqrtPriceX96, liquidity);
        } else {
            amount1 = getAmount1Delta(lower, upper, liquidity);
        }
    }

    /// liquidity * (1/sqrt(a) - 1/sqrt(b)) in currency0, rounded up (SqrtPriceMath.getAmount0Delta).
    function getAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        if (sqrtPriceAX96 == 0) revert InvalidSqrtPrice(0);
        uint256 numerator =
            Math.mulDiv(uint256(liquidity) << 96, sqrtPriceBX96 - sqrtPriceAX96, sqrtPriceBX96, Math.Rounding.Ceil);
        return Math.ceilDiv(numerator, sqrtPriceAX96);
    }

    /// liquidity * (sqrt(b) - sqrt(a)) in currency1, rounded up (SqrtPriceMath.getAmount1Delta).
    function getAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        return Math.mulDiv(liquidity, sqrtPriceBX96 - sqrtPriceAX96, Q96, Math.Rounding.Ceil);
    }

    function toUint128(uint256 x) internal pure returns (uint128) {
        if (x > type(uint128).max) revert LiquidityOverflow(x);
        return uint128(x);
    }

    function _liquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        private
        pure
        returns (uint256)
    {
        uint256 intermediate = Math.mulDiv(sqrtPriceAX96, sqrtPriceBX96, Q96);
        return Math.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96);
    }

    function _liquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        private
        pure
        returns (uint256)
    {
        return Math.mulDiv(amount1, Q96, sqrtPriceBX96 - sqrtPriceAX96);
    }
}
