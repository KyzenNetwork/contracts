// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {SiliconFeeRouter} from "../../src/silicon/SiliconFeeRouter.sol";
import {SiliconSwapAdapter} from "../../src/silicon/SiliconSwapAdapter.sol";
import {IV3SwapRouter02, IV4PoolManager, PoolKey} from "../../src/silicon/interfaces/ISwapVenues.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";
import {SiliconMainnetTerms as Terms} from "../../script/SiliconMainnet.sol";
import {IV4Quoter, QuoteExactSingleParams} from "../../script/interfaces/IUniswapV4.sol";
import {SiliconPoolSeed as Seed} from "../../script/lib/SiliconPoolSeed.sol";
import {MockToken} from "../silicon/mocks/SiliconMocks.sol";

/// Uniswap v3 QuoterV2's single-pool quote.
interface IQuoterV2Single {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// SiliconSwapAdapter on a fork of Robinhood Chain mainnet, as the fee router's target: a stand-in
/// synth with its v4 pool against the real USDG seeded by SiliconPoolSeed (at $100, 0.30%, spacing
/// 60, full range), a SiliconFeeRouter with the adapter queued and live after 24 hours, fee synth
/// and USDG in the router, the keeper's conversions with minimums from the V4Quoter and the v3
/// QuoterV2, then distribute(). Nothing is sent to the chain. Skipped unless ROBINHOOD_RPC_URL
/// names a Robinhood Chain mainnet RPC (the serial forwarder: see SiliconPools.t.sol).
contract SiliconSwapAdapterForkTest is Test {
    /// The USDG/WETH pool the keeper sells into: 0.01%, the deepest USDG pool on the chain.
    uint24 internal constant V3_FEE = 100;
    /// The keeper's tolerance below the quotes. A test value only: the mainnet keeper chooses its own.
    uint256 internal constant TEST_TOLERANCE_BPS = 10;

    /// Stand-in synths: one below USDG's address (currency0: the synth sells zeroForOne) and two
    /// above it (currency1: oneForZero).
    address internal constant LOW = address(0x1000000000000000000000000000000000000001);
    address internal constant HIGH = address(0x9000000000000000000000000000000000000009);
    address internal constant HIGH_THIN = address(0x9000000000000000000000000000000000000019);

    SiliconSwapAdapter internal adapter;
    SiliconFeeRouter internal router;
    MockToken internal synth;
    Seed.Plan internal pool;
    address internal keeper = makeAddr("keeper");
    address internal reserve = makeAddr("reserve");
    address internal stakers = makeAddr("stakers");
    address internal lp = makeAddr("lp");

    function setUp() public {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true, "ROBINHOOD_RPC_URL is not set");
        vm.createSelectFork(url);
        assertEq(block.chainid, RH.CHAIN_ID, "the fork is not Robinhood Chain mainnet");

        // The synth's pool (below USDG), seeded by an LP at $100, full range.
        pool = _seed(LOW, 0, 1_000e18, 100_000e6);
        synth = MockToken(LOW);
        assertTrue(pool.synthIsCurrency0, "LOW sorts below USDG");

        adapter = new SiliconSwapAdapter(
            IV4PoolManager(RH.UNISWAP_V4_POOL_MANAGER), IV3SwapRouter02(RH.UNISWAP_V3_SWAP_ROUTER_02), RH.WETH, RH.USDG
        );
        router = new SiliconFeeRouter(IWETH(RH.WETH));
        router.setKeeper(keeper);
        router.setReserve(reserve);
        router.setStaking(stakers);
        router.setSplit(Terms.RESERVE_SHARE_BPS);
        router.queueTarget(address(adapter), true);
    }

    function _key() internal view returns (PoolKey memory) {
        return pool.key;
    }

    /// A stand-in synth at `token` and its v4 pool against USDG at $100 (0.30%, spacing 60; full range,
    /// or the price plus and minus `rangeBps`), seeded by the LP.
    function _seed(address token, uint256 rangeBps, uint256 synthAmount, uint256 usdgAmount)
        internal
        returns (Seed.Plan memory p)
    {
        deployCodeTo("SiliconMocks.sol:MockToken", abi.encode("kX", uint8(18)), token);
        MockToken(token).mint(lp, synthAmount);
        deal(RH.USDG, lp, usdgAmount);
        p = Seed.plan(
            token,
            RH.USDG,
            100e18,
            synthAmount,
            usdgAmount,
            Seed.Settings({fee: 3000, tickSpacing: 60, rangeBps: rangeBps})
        );
        vm.startPrank(lp);
        Seed.seed(p, lp, block.timestamp + 30 minutes);
        vm.stopPrank();
    }

    /// The WETH the two quoters give for `amountIn` of the synth: the V4Quoter in the synth's pool,
    /// then QuoterV2 in the v3 USDG/WETH pool.
    function _quoteSynth(uint256 amountIn) internal returns (uint256 usdgOut, uint256 wethOut) {
        return _quoteSynthIn(pool, amountIn);
    }

    function _quoteSynthIn(Seed.Plan memory p, uint256 amountIn) internal returns (uint256 usdgOut, uint256 wethOut) {
        (usdgOut,) = IV4Quoter(RH.UNISWAP_V4_QUOTER)
            .quoteExactInputSingle(QuoteExactSingleParams(p.key, p.synthIsCurrency0, uint128(amountIn), ""));
        wethOut = _quoteUsdg(usdgOut);
    }

    function _quoteUsdg(uint256 amountIn) internal returns (uint256 wethOut) {
        (wethOut,,,) = IQuoterV2Single(RH.UNISWAP_V3_QUOTER_V2)
            .quoteExactInputSingle(IQuoterV2Single.QuoteExactInputSingleParams(RH.USDG, RH.WETH, amountIn, V3_FEE, 0));
    }

    function _assertNothingLeft() internal view {
        _assertNothingLeftOf(address(synth));
    }

    function _assertNothingLeftOf(address token) internal view {
        assertEq(IERC20(token).balanceOf(address(adapter)), 0, "synth left in the adapter");
        assertEq(IERC20(RH.USDG).balanceOf(address(adapter)), 0, "USDG left in the adapter");
        assertEq(IERC20(RH.WETH).balanceOf(address(adapter)), 0, "WETH left in the adapter");
        assertEq(address(adapter).balance, 0, "ETH left in the adapter");
        assertEq(IERC20(RH.USDG).allowance(address(adapter), RH.UNISWAP_V3_SWAP_ROUTER_02), 0, "adapter approval");
        assertEq(IERC20(token).allowance(address(router), address(adapter)), 0, "router synth approval");
        assertEq(IERC20(RH.USDG).allowance(address(router), address(adapter)), 0, "router USDG approval");
    }

    /// Fee synth (as the vault mints it) and USDG in the router become WETH through the adapter at
    /// the quoted amounts, and distribute() pays the Reserve's share and the stakers' share in ETH.
    function test_the_fee_router_sells_synth_and_usdg_through_the_adapter() public {
        uint256 synthFees = 10e18;
        uint256 usdgFees = 500e6;
        synth.mint(address(router), synthFees);
        deal(RH.USDG, address(router), usdgFees);
        bytes memory sellSynth = abi.encodeCall(SiliconSwapAdapter.sellSynth, (_key(), synthFees, V3_FEE));
        bytes memory sellUsdg = abi.encodeCall(SiliconSwapAdapter.sellUsdg, (usdgFees, V3_FEE));

        // Not a target until its 24 hours have passed.
        vm.prank(keeper);
        vm.expectRevert(SiliconFeeRouter.BadTarget.selector);
        router.convert(address(synth), address(adapter), sellSynth, synthFees, 0);
        vm.warp(block.timestamp + 24 hours);

        (uint256 usdgQuoted, uint256 wethQuoted) = _quoteSynth(synthFees);
        // 10 synth at $100 is $1,000, less the 0.30% fee and about 1% of price impact (the pool
        // holds 1,000 synth).
        assertGt(usdgQuoted, 980e6, "USDG quoted, low");
        assertLt(usdgQuoted, 997e6, "USDG quoted, high");
        uint256 minOut = wethQuoted * (10_000 - TEST_TOLERANCE_BPS) / 10_000;

        // Below the keeper's minimum the whole conversion reverts.
        vm.prank(keeper);
        vm.expectRevert(
            abi.encodeWithSelector(SiliconFeeRouter.InsufficientOutput.selector, wethQuoted, wethQuoted + 1)
        );
        router.convert(address(synth), address(adapter), sellSynth, synthFees, wethQuoted + 1);

        vm.prank(keeper);
        uint256 fromSynth = router.convert(address(synth), address(adapter), sellSynth, synthFees, minOut);
        assertEq(fromSynth, wethQuoted, "synth: the quoted WETH");
        assertEq(synth.balanceOf(address(router)), 0, "all the fee synth sold");
        _assertNothingLeft();

        uint256 wethQuotedUsdg = _quoteUsdg(usdgFees);
        vm.prank(keeper);
        uint256 fromUsdg = router.convert(
            RH.USDG, address(adapter), sellUsdg, usdgFees, wethQuotedUsdg * (10_000 - TEST_TOLERANCE_BPS) / 10_000
        );
        assertEq(fromUsdg, wethQuotedUsdg, "USDG: the quoted WETH");
        assertEq(IERC20(RH.USDG).balanceOf(address(router)), 0, "all the USDG sold");
        _assertNothingLeft();

        uint256 total = fromSynth + fromUsdg;
        assertEq(IERC20(RH.WETH).balanceOf(address(router)), total);
        (uint256 toReserve, uint256 toStakers) = router.distribute();
        assertEq(toReserve + toStakers, total);
        assertEq(toReserve, total * Terms.RESERVE_SHARE_BPS / 10_000);
        assertEq(reserve.balance, toReserve);
        assertEq(stakers.balance, toStakers);
        assertEq(IERC20(RH.WETH).balanceOf(address(router)), 0);
        assertEq(address(router).balance, 0);
        console2.log("10 synth -> USDG (quoted)", usdgQuoted);
        console2.log("10 synth -> WETH         ", fromSynth);
        console2.log("500 USDG -> WETH         ", fromUsdg);
        console2.log("to the Reserve, stakers  ", toReserve, toStakers);
    }

    /// The oneForZero branch on the real PoolManager: a synth that sorts above USDG is currency1
    /// and sells oneForZero, at exactly the quoted WETH. (Adopted from the adapter review.)
    function test_sells_a_synth_that_sorts_above_usdg() public {
        Seed.Plan memory p = _seed(HIGH, 0, 1_000e18, 100_000e6);
        assertFalse(p.synthIsCurrency0, "HIGH sorts above USDG");
        MockToken(HIGH).mint(address(router), 10e18);
        vm.warp(block.timestamp + 24 hours);
        (, uint256 wethQuoted) = _quoteSynthIn(p, 10e18);
        bytes memory data = abi.encodeCall(SiliconSwapAdapter.sellSynth, (p.key, 10e18, V3_FEE));
        vm.prank(keeper);
        uint256 got =
            router.convert(HIGH, address(adapter), data, 10e18, wethQuoted * (10_000 - TEST_TOLERANCE_BPS) / 10_000);
        assertEq(got, wethQuoted, "the quoted WETH");
        assertEq(MockToken(HIGH).balanceOf(address(router)), 0, "all sold");
        _assertNothingLeftOf(HIGH);
        console2.log("oneForZero: 10 synth -> WETH", got);
    }

    /// A partial fill on the real PoolManager: a thin pool (10 synth and 1,000 USDG in plus and
    /// minus 1% of the price) takes only what its range can hold of a 1,000-synth sale, and the
    /// adapter returns the rest of the synth to the router in the same call. (Adopted from the
    /// adapter review.)
    function test_returns_what_a_thin_pool_does_not_take() public {
        Seed.Plan memory q = _seed(HIGH_THIN, 100, 10e18, 1_000e6);
        uint256 amountIn = 1_000e18;
        MockToken(HIGH_THIN).mint(address(router), amountIn);
        uint256 pmBefore = MockToken(HIGH_THIN).balanceOf(RH.UNISWAP_V4_POOL_MANAGER);
        vm.warp(block.timestamp + 24 hours);
        bytes memory data = abi.encodeCall(SiliconSwapAdapter.sellSynth, (q.key, amountIn, V3_FEE));
        vm.prank(keeper);
        uint256 got = router.convert(HIGH_THIN, address(adapter), data, amountIn, 1);
        uint256 paid = MockToken(HIGH_THIN).balanceOf(RH.UNISWAP_V4_POOL_MANAGER) - pmBefore;
        uint256 back = MockToken(HIGH_THIN).balanceOf(address(router));
        assertGt(got, 0, "some WETH");
        assertGt(paid, 0, "the pool took some");
        assertGt(back, 0, "some synth returned");
        assertEq(paid + back, amountIn, "what the pool did not take came back");
        _assertNothingLeftOf(HIGH_THIN);
        console2.log("partial fill: WETH, synth taken, synth returned", got, paid, back);
    }
}
