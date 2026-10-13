// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {RobinhoodChain as RH} from "../RobinhoodChain.sol";
import {IPermit2, IV4PositionManager, IV4StateView, PoolKey} from "../interfaces/IUniswapV4.sol";
import {V4PoolMath as M} from "./V4PoolMath.sol";

/// One Silicon index synth's Uniswap v4 pool against USDG (SPEC 3.5, Venue) and the owner's seed
/// position in it, shared by script/SiliconPools.s.sol and test/fork/SiliconPools.t.sol.
///
/// plan() reads nothing but the synth's and USDG's decimals and the pool's state: it refuses a pool
/// that is already initialised, prices the pool at the index's USD price with USDG at $1.00 (token
/// order by address), and works out the position the owner's two amounts pay for. seed() then sends,
/// from the owner: each token's approval to Permit2 and Permit2's approval of the PositionManager
/// (both for exactly the position's maxima, until the deadline), and one PositionManager multicall
/// that initialises the pool and mints the position (MINT_POSITION, SETTLE_PAIR), the NFT to the
/// owner. check() reads the result back.
///
/// The initialisation and the mint are one transaction, so no one can trade the empty pool between
/// them. If someone initialises the pool first at another price, initializePool returns without
/// reverting (v4-periphery's PoolInitializer) and the mint would run at their price: the maxima
/// stop that, since any other price asks more of one of the two tokens than the maxima allow.
///
/// planBid() plans a USDG-only bid instead (SPEC 3.5: each pool seeded with USDG as a single-sided
/// bid from the index price down): the synth's maximum is zero and the synth is not approved. If
/// someone initialises the pool first, a price at or below the bid's top would put the bid in range,
/// where it needs synth, and the mint reverts; a higher price leaves the bid USDG-only at its own
/// ticks, so the owner's USDG still buys synth only at or below the index price it was planned at.
library SiliconPoolSeed {
    /// The pool's fee and tick spacing, and the position's range: 0 for the full range, otherwise
    /// the index price plus and minus rangeBps basis points, widened to the tick spacing.
    struct Settings {
        uint24 fee;
        int24 tickSpacing;
        uint256 rangeBps;
    }

    struct Plan {
        PoolKey key;
        bytes32 poolId;
        address synth;
        bool synthIsCurrency0;
        /// USD per whole synth, 18 decimals, from the index feed.
        uint256 usdPrice;
        /// 10^(18 + synth decimals - USDG decimals).
        uint256 scale;
        uint160 sqrtPriceX96;
        int24 tick;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        /// What the mint takes of currency0 and currency1 at the starting price.
        uint256 amount0;
        uint256 amount1;
        /// The mint's maxima: amount0 and amount1 plus the rounding allowance, never above what the
        /// owner offered.
        uint256 amount0Max;
        uint256 amount1Max;
    }

    uint256 internal constant BPS = 10_000;
    /// v4-core's LPFeeLibrary.MAX_LP_FEE (100%); a static fee must be below it.
    uint24 internal constant MAX_LP_FEE = 1_000_000;
    /// v4-core's TickMath.MAX_TICK_SPACING.
    int24 internal constant MAX_TICK_SPACING = type(int16).max;
    /// The maxima's allowance over what the mint takes, in parts per million: covers rounding
    /// only. A starting price one tick away changes the binding amount by about 50 parts per
    /// million, so it reverts.
    uint256 internal constant ROUNDING_PPM = 1;
    /// v4-periphery's Actions.
    uint8 internal constant DECREASE_LIQUIDITY = 0x01;
    uint8 internal constant MINT_POSITION = 0x02;
    uint8 internal constant SETTLE_PAIR = 0x0d;
    uint8 internal constant TAKE_PAIR = 0x11;

    /// A fee at or above 100% (or a dynamic-fee flag), a tick spacing outside 1 to 32767, or a
    /// range of 100% or more.
    error BadSettings(uint24 fee, int24 tickSpacing, uint256 rangeBps);
    /// The index has no price.
    error NoPrice();
    /// Both amounts must be above zero.
    error NoAmount();
    /// USDG has more decimals than 18 plus the synth's.
    error BadDecimals(uint8 synthDecimals, uint8 usdgDecimals);
    /// The pool already has a price: someone initialised it, or it was seeded before.
    error PoolExists(bytes32 poolId, uint160 sqrtPriceX96);
    /// The amounts pay for no liquidity at this price.
    error NoLiquidity();
    /// An amount does not fit the mint's 128-bit maxima.
    error AmountTooLarge(uint256 amount);
    error ApproveFailed(address token);
    /// A bid's range would hold synth.
    error NotABid();
    /// The pool has no price: there is nothing to re-place a bid in.
    error PoolMissing(bytes32 poolId);
    /// The new bid would not sit wholly on the USDG side of the pool's price (the pool's price is
    /// below the bid's top, so the bid would need synth).
    error BidNotBesidePrice(int24 poolTick, int24 tickLower, int24 tickUpper);
    /// The pool or the position does not read back as planned.
    error Mismatch(string what, uint256 expected, uint256 actual);

    function checkSettings(Settings memory s) internal pure {
        if (s.fee >= MAX_LP_FEE || s.tickSpacing < 1 || s.tickSpacing > MAX_TICK_SPACING || s.rangeBps >= BPS) {
            revert BadSettings(s.fee, s.tickSpacing, s.rangeBps);
        }
    }

    /// The pool for `synth` against `usdg` at `usdPrice` (USD per whole synth, 18 decimals), and
    /// the two-sided position `synthAmount` and `usdgAmount` (base units) pay for, over the full
    /// range or the price plus and minus rangeBps. Reverts if the pool already has a price.
    function plan(
        address synth,
        address usdg,
        uint256 usdPrice,
        uint256 synthAmount,
        uint256 usdgAmount,
        Settings memory s
    ) internal view returns (Plan memory p) {
        if (synthAmount == 0 || usdgAmount == 0) revert NoAmount();
        p = _start(synth, usdg, usdPrice, s);
        (p.tickLower, p.tickUpper) = _range(p, s);
        (uint256 offered0, uint256 offered1) =
            p.synthIsCurrency0 ? (synthAmount, usdgAmount) : (usdgAmount, synthAmount);
        _size(p, offered0, offered1);
    }

    /// The pool for `synth` against `usdg` at `usdPrice`, as plan(), and a USDG-only bid of
    /// `usdgAmount`: a position from the first usable tick below the index price down to the
    /// index price less rangeBps (widened to the tick spacing), where the pool holds only USDG
    /// until someone sells synth into it. When USDG is currency1 the bid sits below the pool's
    /// tick (tickUpper <= tick); when USDG is currency0 a lower synth price is a higher pool price,
    /// and the bid sits above it (tick < tickLower). It takes no synth. Reverts if the pool already
    /// has a price, or with BadSettings for a rangeBps of 0 (a bid needs a depth).
    function planBid(address synth, address usdg, uint256 usdPrice, uint256 usdgAmount, Settings memory s)
        internal
        view
        returns (Plan memory p)
    {
        if (s.rangeBps == 0) revert BadSettings(s.fee, s.tickSpacing, s.rangeBps);
        if (usdgAmount == 0) revert NoAmount();
        p = _start(synth, usdg, usdPrice, s);
        (p.tickLower, p.tickUpper) = _bidRange(p, s);
        (uint256 offered0, uint256 offered1) = p.synthIsCurrency0 ? (uint256(0), usdgAmount) : (usdgAmount, uint256(0));
        _size(p, offered0, offered1);
        (uint256 synthMax,) = maxima(p);
        if (synthMax != 0) revert NotABid();
    }

    /// A USDG-only bid of `usdgAmount` in the existing pool for `synth`, placed as planBid places it
    /// (from the first usable tick below the index price down rangeBps) but sized at the pool's
    /// current price, which a re-placing run first moves to the index price. Reverts if the pool has
    /// no price, or if the pool's price is not above the bid's top (the bid would need synth).
    function planBidAt(address synth, address usdg, uint256 usdPrice, uint256 usdgAmount, Settings memory s)
        internal
        view
        returns (Plan memory p)
    {
        if (s.rangeBps == 0) revert BadSettings(s.fee, s.tickSpacing, s.rangeBps);
        if (usdgAmount == 0) revert NoAmount();
        p = _head(synth, usdg, usdPrice, s);
        // The range follows the index price (p.tick is the index's tick here) ...
        (p.tickLower, p.tickUpper) = _bidRange(p, s);
        // ... and the sizing the pool's own price.
        (uint160 current, int24 poolTick,,) = IV4StateView(RH.UNISWAP_V4_STATE_VIEW).getSlot0(p.poolId);
        if (current == 0) revert PoolMissing(p.poolId);
        p.sqrtPriceX96 = current;
        p.tick = poolTick;
        bool beside = p.synthIsCurrency0 ? p.tickUpper <= poolTick : poolTick < p.tickLower;
        if (!beside) revert BidNotBesidePrice(poolTick, p.tickLower, p.tickUpper);
        (uint256 offered0, uint256 offered1) = p.synthIsCurrency0 ? (uint256(0), usdgAmount) : (usdgAmount, uint256(0));
        _size(p, offered0, offered1);
        (uint256 synthMax,) = maxima(p);
        if (synthMax != 0) revert NotABid();
    }

    /// The pool key for `synth` against `usdg` with these settings (no hook).
    function keyFor(address synth, address usdg, Settings memory s) internal pure returns (PoolKey memory) {
        bool synthIsCurrency0 = synth < usdg;
        return PoolKey({
            currency0: synthIsCurrency0 ? synth : usdg,
            currency1: synthIsCurrency0 ? usdg : synth,
            fee: s.fee,
            tickSpacing: s.tickSpacing,
            hooks: address(0)
        });
    }

    /// Removes all of position `tokenId`'s liquidity and takes everything it holds, its fees
    /// included, to `recipient` (DECREASE_LIQUIDITY, TAKE_PAIR), from the caller (the position's
    /// owner, under a broadcast or a prank). The NFT stays the owner's, with no liquidity. No
    /// minimum amounts: a bid can only return its USDG, or synth bought at the bid's own prices.
    function removeAll(uint256 tokenId, PoolKey memory key, address recipient, uint256 deadline) internal {
        IV4PositionManager posm = IV4PositionManager(RH.UNISWAP_V4_POSITION_MANAGER);
        uint128 liquidity = posm.getPositionLiquidity(tokenId);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(tokenId, uint256(liquidity), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, recipient);
        posm.modifyLiquidities(abi.encode(abi.encodePacked(DECREASE_LIQUIDITY, TAKE_PAIR), params), deadline);
    }

    /// The new position reads back: the pool at the planned price and fee, the NFT the owner's with
    /// the planned liquidity. (The pool's active liquidity is not compared: others may hold
    /// positions in an existing pool.)
    function checkPosition(Plan memory p, uint256 tokenId, address owner) internal view {
        IV4PositionManager posm = IV4PositionManager(RH.UNISWAP_V4_POSITION_MANAGER);
        (uint160 sqrtPriceX96,,, uint24 lpFee) = IV4StateView(RH.UNISWAP_V4_STATE_VIEW).getSlot0(p.poolId);
        _same("pool sqrtPriceX96", p.sqrtPriceX96, sqrtPriceX96);
        _same("pool lp fee", p.key.fee, lpFee);
        _same("position liquidity", p.liquidity, posm.getPositionLiquidity(tokenId));
        _same("position owner", uint160(owner), uint160(posm.ownerOf(tokenId)));
    }

    /// What the mint may take of the synth and of USDG.
    function maxima(Plan memory p) internal pure returns (uint256 synthMax, uint256 usdgMax) {
        return p.synthIsCurrency0 ? (p.amount0Max, p.amount1Max) : (p.amount1Max, p.amount0Max);
    }

    /// What the mint takes of the synth and of USDG at the starting price.
    function amounts(Plan memory p) internal pure returns (uint256 synthAmount, uint256 usdgAmount) {
        return p.synthIsCurrency0 ? (p.amount0, p.amount1) : (p.amount1, p.amount0);
    }

    /// Sends the approvals and the multicall from the caller (the owner, under a broadcast or a
    /// prank); the position NFT goes to `owner`. Returns the NFT's id as of the call. A token the
    /// mint may not take (the synth of a bid) is not approved.
    function seed(Plan memory p, address owner, uint256 deadline) internal returns (uint256 tokenId) {
        IV4PositionManager posm = IV4PositionManager(RH.UNISWAP_V4_POSITION_MANAGER);
        if (p.amount0Max != 0) _approve(p.key.currency0, p.amount0Max, deadline);
        if (p.amount1Max != 0) _approve(p.key.currency1, p.amount1Max, deadline);

        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(
            p.key,
            p.tickLower,
            p.tickUpper,
            uint256(p.liquidity),
            uint128(p.amount0Max),
            uint128(p.amount1Max),
            owner,
            bytes("")
        );
        params[1] = abi.encode(p.key.currency0, p.key.currency1);
        bytes memory actions = abi.encodePacked(MINT_POSITION, SETTLE_PAIR);

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(IV4PositionManager.initializePool, (p.key, p.sqrtPriceX96));
        calls[1] = abi.encodeCall(IV4PositionManager.modifyLiquidities, (abi.encode(actions, params), deadline));
        tokenId = posm.nextTokenId();
        posm.multicall(calls);
    }

    /// The pool is at the planned price, tick and fee with the position's liquidity active at its
    /// price (none for a bid), and the NFT is the owner's with that liquidity.
    function check(Plan memory p, uint256 tokenId, address owner) internal view {
        IV4StateView view_ = IV4StateView(RH.UNISWAP_V4_STATE_VIEW);
        IV4PositionManager posm = IV4PositionManager(RH.UNISWAP_V4_POSITION_MANAGER);
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = view_.getSlot0(p.poolId);
        _same("pool sqrtPriceX96", p.sqrtPriceX96, sqrtPriceX96);
        _same("pool tick", uint256(int256(p.tick) - M.MIN_TICK), uint256(int256(tick) - M.MIN_TICK));
        _same("pool lp fee", p.key.fee, lpFee);
        // The pool's active liquidity is the position's while the position holds the pool's tick,
        // and zero for a bid, which sits beside it.
        bool inRange = p.tickLower <= tick && tick < p.tickUpper;
        _same("pool liquidity", inRange ? p.liquidity : 0, view_.getLiquidity(p.poolId));
        _same("position liquidity", p.liquidity, posm.getPositionLiquidity(tokenId));
        _same("position owner", uint160(owner), uint160(posm.ownerOf(tokenId)));
    }

    /// The pool's key, id and starting price; refuses settings out of range, no price, odd decimals
    /// and a pool that already has a price.
    function _start(address synth, address usdg, uint256 usdPrice, Settings memory s)
        private
        view
        returns (Plan memory p)
    {
        p = _head(synth, usdg, usdPrice, s);
        (uint160 current,,,) = IV4StateView(RH.UNISWAP_V4_STATE_VIEW).getSlot0(p.poolId);
        if (current != 0) revert PoolExists(p.poolId, current);
    }

    /// The pool's key and id, and the index price as a pool price and tick; refuses settings out of
    /// range, no price and odd decimals.
    function _head(address synth, address usdg, uint256 usdPrice, Settings memory s)
        private
        view
        returns (Plan memory p)
    {
        checkSettings(s);
        if (usdPrice == 0) revert NoPrice();
        uint8 synthDecimals = IERC20Metadata(synth).decimals();
        uint8 usdgDecimals = IERC20Metadata(usdg).decimals();
        if (uint256(usdgDecimals) > 18 + uint256(synthDecimals)) revert BadDecimals(synthDecimals, usdgDecimals);

        p.synth = synth;
        p.usdPrice = usdPrice;
        p.scale = 10 ** (18 + uint256(synthDecimals) - uint256(usdgDecimals));
        p.synthIsCurrency0 = synth < usdg;
        p.key = keyFor(synth, usdg, s);
        p.poolId = keccak256(abi.encode(p.key));
        p.sqrtPriceX96 = M.sqrtPriceForUsd(usdPrice, p.synthIsCurrency0, p.scale);
        p.tick = M.getTickAtSqrtPrice(p.sqrtPriceX96);
    }

    /// The liquidity the offered amounts pay for in the planned range, what the mint takes and its
    /// maxima.
    function _size(Plan memory p, uint256 offered0, uint256 offered1) private pure {
        p.liquidity = M.getLiquidityForAmounts(
            p.sqrtPriceX96, M.getSqrtPriceAtTick(p.tickLower), M.getSqrtPriceAtTick(p.tickUpper), offered0, offered1
        );
        if (p.liquidity == 0) revert NoLiquidity();
        (p.amount0, p.amount1) = M.getAmountsForLiquidity(p.sqrtPriceX96, p.tick, p.tickLower, p.tickUpper, p.liquidity);
        p.amount0Max = Math.min(offered0, p.amount0 + p.amount0 * ROUNDING_PPM / 1e6 + 1);
        p.amount1Max = Math.min(offered1, p.amount1 + p.amount1 * ROUNDING_PPM / 1e6 + 1);
        if (p.amount0Max > type(uint128).max) revert AmountTooLarge(p.amount0Max);
        if (p.amount1Max > type(uint128).max) revert AmountTooLarge(p.amount1Max);
    }

    /// A bid's ticks: from the first usable tick past the index price (toward a lower synth price)
    /// to the index price less rangeBps, widened to the tick spacing.
    function _bidRange(Plan memory p, Settings memory s) private pure returns (int24 lower, int24 upper) {
        int24 deep =
            M.getTickAtSqrtPrice(M.sqrtPriceForUsd(p.usdPrice * (BPS - s.rangeBps) / BPS, p.synthIsCurrency0, p.scale));
        if (p.synthIsCurrency0) {
            // USDG is currency1: the position holds only USDG while tick >= tickUpper.
            upper = M.floorToSpacing(p.tick, s.tickSpacing);
            lower = M.floorToSpacing(deep, s.tickSpacing);
            if (lower >= upper) lower = upper - s.tickSpacing;
        } else {
            // USDG is currency0: the position holds only USDG while tick < tickLower.
            lower = M.floorToSpacing(p.tick, s.tickSpacing) + s.tickSpacing;
            upper = M.ceilToSpacing(deep, s.tickSpacing);
            if (upper <= lower) upper = lower + s.tickSpacing;
        }
        int24 minTick = M.minUsableTick(s.tickSpacing);
        int24 maxTick = M.maxUsableTick(s.tickSpacing);
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
    }

    function _range(Plan memory p, Settings memory s) private pure returns (int24 lower, int24 upper) {
        if (s.rangeBps == 0) return (M.minUsableTick(s.tickSpacing), M.maxUsableTick(s.tickSpacing));
        uint160 a = M.sqrtPriceForUsd(p.usdPrice * (BPS - s.rangeBps) / BPS, p.synthIsCurrency0, p.scale);
        uint160 b = M.sqrtPriceForUsd(p.usdPrice * (BPS + s.rangeBps) / BPS, p.synthIsCurrency0, p.scale);
        if (a > b) (a, b) = (b, a);
        lower = M.floorToSpacing(M.getTickAtSqrtPrice(a), s.tickSpacing);
        upper = M.ceilToSpacing(M.getTickAtSqrtPrice(b), s.tickSpacing);
        // The position must hold the starting tick: tickLower <= tick < tickUpper.
        if (upper <= p.tick) upper = M.floorToSpacing(p.tick, s.tickSpacing) + s.tickSpacing;
        int24 minTick = M.minUsableTick(s.tickSpacing);
        int24 maxTick = M.maxUsableTick(s.tickSpacing);
        if (lower < minTick) lower = minTick;
        if (upper > maxTick) upper = maxTick;
    }

    function _approve(address token, uint256 amount, uint256 deadline) private {
        if (!IERC20(token).approve(RH.PERMIT2, amount)) revert ApproveFailed(token);
        IPermit2(RH.PERMIT2).approve(token, RH.UNISWAP_V4_POSITION_MANAGER, uint160(amount), uint48(deadline));
    }

    function _same(string memory what, uint256 expected, uint256 actual) private pure {
        if (expected != actual) revert Mismatch(what, expected, actual);
    }
}
