// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {SiliconFeeRouter} from "../../src/silicon/SiliconFeeRouter.sol";
import {SiliconSwapAdapter} from "../../src/silicon/SiliconSwapAdapter.sol";
import {
    IV3SwapRouter02,
    IV4PoolManager,
    IV4UnlockCallback,
    PoolKey,
    SwapParams
} from "../../src/silicon/interfaces/ISwapVenues.sol";
import {MockToken} from "./mocks/SiliconMocks.sol";

/// A v4 PoolManager stand-in: one swap per unlock at a set rate, taking a set share of the input
/// (a pool that runs out of liquidity takes less). It pays out of its own balance and reverts the
/// unlock unless the caller settled the input and took the output exactly.
contract MockV4PoolManager {
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    uint256 public fillBps = 10_000;
    bool internal unlocked;
    address internal synced;
    uint256 internal syncedBalance;
    mapping(address => uint256) public owed; // what the locker must pay in
    mapping(address => uint256) public due; // what the locker may take out
    address internal tokenIn;
    address internal tokenOut;

    function set(uint256 num, uint256 den, uint256 fill) external {
        (rateNum, rateDen, fillBps) = (num, den, fill);
    }

    function unlock(bytes calldata data) external returns (bytes memory result) {
        unlocked = true;
        result = IV4UnlockCallback(msg.sender).unlockCallback(data);
        unlocked = false;
        require(owed[tokenIn] == 0 && due[tokenOut] == 0, "deltas open");
    }

    function swap(PoolKey memory key, SwapParams memory p, bytes calldata) external returns (int256) {
        require(unlocked, "locked");
        require(p.amountSpecified < 0, "exact input only");
        uint256 amountIn = uint256(-p.amountSpecified) * fillBps / 10_000;
        uint256 amountOut = amountIn * rateNum / rateDen;
        (tokenIn, tokenOut) = p.zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        owed[tokenIn] += amountIn;
        due[tokenOut] += amountOut;
        int128 dIn = -int128(int256(amountIn));
        int128 dOut = int128(int256(amountOut));
        (int128 a0, int128 a1) = p.zeroForOne ? (dIn, dOut) : (dOut, dIn);
        return int256((uint256(uint128(a0)) << 128) | uint256(uint128(a1)));
    }

    function sync(address currency) external {
        synced = currency;
        syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable returns (uint256 paid) {
        paid = IERC20(synced).balanceOf(address(this)) - syncedBalance;
        owed[synced] -= paid;
    }

    function take(address currency, address to, uint256 amount) external {
        due[currency] -= amount;
        require(IERC20(currency).transfer(to, amount), "take");
    }
}

/// A v3 SwapRouter02 stand-in: pulls a set share of the input by allowance and mints the output
/// (an open-mint token) to the recipient at a set rate.
contract MockSwapRouter02 {
    uint256 public rateNum = 1;
    uint256 public rateDen = 1;
    uint256 public fillBps = 10_000;

    function set(uint256 num, uint256 den, uint256 fill) external {
        (rateNum, rateDen, fillBps) = (num, den, fill);
    }

    function exactInputSingle(IV3SwapRouter02.ExactInputSingleParams calldata p) external payable returns (uint256) {
        uint256 amountIn = p.amountIn * fillBps / 10_000;
        require(IERC20(p.tokenIn).transferFrom(msg.sender, address(this), amountIn), "pull");
        uint256 amountOut = amountIn * rateNum / rateDen;
        MockToken(p.tokenOut).mint(p.recipient, amountOut);
        return amountOut;
    }
}

/// SiliconSwapAdapter against stand-ins for the PoolManager and SwapRouter02: both routes, both
/// token orders, partial fills returned, nothing left behind, refusals, and a conversion through
/// SiliconFeeRouter.
contract SiliconSwapAdapterTest is Test {
    // Synths on both sides of USDG's address.
    address internal constant USDG_AT = address(0x5000000000000000000000000000000000000005);
    address internal constant LOW_SYNTH_AT = address(0x1000000000000000000000000000000000000001);
    address internal constant HIGH_SYNTH_AT = address(0x9000000000000000000000000000000000000009);

    MockV4PoolManager internal pm;
    MockSwapRouter02 internal router02;
    MockToken internal weth;
    MockToken internal usdg;
    MockToken internal low; // synth below USDG: currency0
    MockToken internal high; // synth above USDG: currency1
    SiliconSwapAdapter internal adapter;
    address internal caller = makeAddr("caller");

    function setUp() public {
        pm = new MockV4PoolManager();
        router02 = new MockSwapRouter02();
        weth = new MockToken("WETH", 18);
        deployCodeTo("SiliconMocks.sol:MockToken", abi.encode("USDG", uint8(6)), USDG_AT);
        deployCodeTo("SiliconMocks.sol:MockToken", abi.encode("kDESIGN", uint8(18)), LOW_SYNTH_AT);
        deployCodeTo("SiliconMocks.sol:MockToken", abi.encode("kMEMORY", uint8(18)), HIGH_SYNTH_AT);
        usdg = MockToken(USDG_AT);
        low = MockToken(LOW_SYNTH_AT);
        high = MockToken(HIGH_SYNTH_AT);
        adapter = new SiliconSwapAdapter(
            IV4PoolManager(address(pm)), IV3SwapRouter02(address(router02)), address(weth), USDG_AT
        );
        // The pool pays USDG out of its own balance: 100 USDG (6 decimals) per synth (18 decimals).
        pm.set(100e6, 1e18, 10_000);
        usdg.mint(address(pm), 1_000_000e6);
        // 1 WETH (18 decimals) per 4,000 USDG (6 decimals).
        router02.set(1e18, 4_000e6, 10_000);
    }

    function _key(address synth) internal pure returns (PoolKey memory) {
        (address c0, address c1) = synth < USDG_AT ? (synth, USDG_AT) : (USDG_AT, synth);
        return PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: address(0)});
    }

    function _sellSynth(MockToken synth, uint256 amountIn) internal returns (uint256 wethOut) {
        synth.mint(caller, amountIn);
        vm.startPrank(caller);
        synth.approve(address(adapter), amountIn);
        wethOut = adapter.sellSynth(_key(address(synth)), amountIn, 100);
        vm.stopPrank();
    }

    function _assertNothingLeft() internal view {
        assertEq(low.balanceOf(address(adapter)), 0, "synth left");
        assertEq(high.balanceOf(address(adapter)), 0, "synth left");
        assertEq(usdg.balanceOf(address(adapter)), 0, "USDG left");
        assertEq(weth.balanceOf(address(adapter)), 0, "WETH left");
        assertEq(address(adapter).balance, 0, "ETH left");
        assertEq(usdg.allowance(address(adapter), address(router02)), 0, "approval left");
    }

    // ---------------------------------------------------------------- construction

    function test_constructor_refuses_zero_or_equal_addresses() public {
        IV4PoolManager p = IV4PoolManager(address(pm));
        IV3SwapRouter02 r = IV3SwapRouter02(address(router02));
        vm.expectRevert(SiliconSwapAdapter.BadAddress.selector);
        new SiliconSwapAdapter(IV4PoolManager(address(0)), r, address(weth), USDG_AT);
        vm.expectRevert(SiliconSwapAdapter.BadAddress.selector);
        new SiliconSwapAdapter(p, IV3SwapRouter02(address(0)), address(weth), USDG_AT);
        vm.expectRevert(SiliconSwapAdapter.BadAddress.selector);
        new SiliconSwapAdapter(p, r, address(0), USDG_AT);
        vm.expectRevert(SiliconSwapAdapter.BadAddress.selector);
        new SiliconSwapAdapter(p, r, address(weth), address(0));
        vm.expectRevert(SiliconSwapAdapter.BadAddress.selector);
        new SiliconSwapAdapter(p, r, USDG_AT, USDG_AT);
        assertEq(address(adapter.poolManager()), address(pm));
        assertEq(address(adapter.swapRouter()), address(router02));
        assertEq(adapter.weth(), address(weth));
        assertEq(adapter.usdg(), USDG_AT);
    }

    // ---------------------------------------------------------------- the routes

    /// 2 synth at $100 is 200 USDG, which is 0.05 WETH at $4,000, in either token order.
    function test_sells_a_synth_for_weth_in_either_token_order() public {
        assertEq(_sellSynth(low, 2e18), 0.05e18);
        assertEq(weth.balanceOf(caller), 0.05e18);
        assertEq(_sellSynth(high, 2e18), 0.05e18);
        assertEq(weth.balanceOf(caller), 0.1e18);
        assertEq(low.balanceOf(address(pm)), 2e18);
        assertEq(high.balanceOf(address(pm)), 2e18);
        assertEq(usdg.balanceOf(address(router02)), 400e6);
        assertEq(low.balanceOf(caller), 0);
        _assertNothingLeft();
    }

    function test_sells_usdg_for_weth() public {
        usdg.mint(caller, 8_000e6);
        vm.startPrank(caller);
        usdg.approve(address(adapter), 8_000e6);
        assertEq(adapter.sellUsdg(8_000e6, 100), 2e18);
        vm.stopPrank();
        assertEq(weth.balanceOf(caller), 2e18);
        assertEq(usdg.balanceOf(caller), 0);
        assertEq(usdg.allowance(caller, address(adapter)), 0);
        _assertNothingLeft();
    }

    /// Pools that take only part of the input: the rest goes back to the caller in the same call.
    function test_returns_what_the_pools_do_not_take() public {
        pm.set(100e6, 1e18, 6_000); // the v4 pool takes 60% of the synth
        router02.set(1e18, 4_000e6, 5_000); // the v3 pool takes half the USDG
        uint256 out = _sellSynth(high, 10e18);
        // 6 synth sold for 600 USDG; 300 USDG sold for 0.075 WETH; 4 synth and 300 USDG returned.
        assertEq(out, 0.075e18);
        assertEq(weth.balanceOf(caller), 0.075e18);
        assertEq(high.balanceOf(caller), 4e18);
        assertEq(usdg.balanceOf(caller), 300e6);
        _assertNothingLeft();

        usdg.mint(caller, 1_000e6);
        vm.startPrank(caller);
        usdg.approve(address(adapter), 1_000e6);
        assertEq(adapter.sellUsdg(1_000e6, 100), 0.125e18);
        vm.stopPrank();
        assertEq(usdg.balanceOf(caller), 300e6 + 500e6);
        _assertNothingLeft();
    }

    /// Tokens sent straight to the adapter are never swept by a caller: every amount it spends or
    /// returns is what it pulled or what a pool paid it in that call.
    function test_a_caller_cannot_sweep_tokens_sent_to_the_adapter() public {
        usdg.mint(address(adapter), 777e6);
        high.mint(address(adapter), 7e18);
        pm.set(100e6, 1e18, 6_000);
        router02.set(1e18, 4_000e6, 5_000);
        _sellSynth(high, 10e18);
        assertEq(high.balanceOf(caller), 4e18);
        assertEq(usdg.balanceOf(caller), 300e6);
        assertEq(usdg.balanceOf(address(adapter)), 777e6);
        assertEq(high.balanceOf(address(adapter)), 7e18);
    }

    /// The adapter pulls only from its caller: an allowance someone else gave it is no use to a
    /// caller with nothing of its own.
    function test_pulls_only_from_the_caller() public {
        address victim = makeAddr("victim");
        usdg.mint(victim, 1_000e6);
        vm.prank(victim);
        usdg.approve(address(adapter), type(uint256).max);
        vm.prank(caller);
        vm.expectRevert();
        adapter.sellUsdg(1_000e6, 100);
        assertEq(usdg.balanceOf(victim), 1_000e6);
    }

    // ---------------------------------------------------------------- refusals

    function test_refuses_bad_pools_and_amounts() public {
        PoolKey memory k = _key(address(high));
        k.hooks = address(0xBEEF);
        vm.expectRevert(SiliconSwapAdapter.BadPool.selector);
        adapter.sellSynth(k, 1e18, 100);

        // No USDG side.
        k = PoolKey({currency0: address(low), currency1: address(high), fee: 3000, tickSpacing: 60, hooks: address(0)});
        vm.expectRevert(SiliconSwapAdapter.BadPool.selector);
        adapter.sellSynth(k, 1e18, 100);

        // Native ETH, WETH or USDG itself as the synth.
        k = PoolKey({currency0: address(0), currency1: USDG_AT, fee: 3000, tickSpacing: 60, hooks: address(0)});
        vm.expectRevert(SiliconSwapAdapter.BadPool.selector);
        adapter.sellSynth(k, 1e18, 100);
        vm.expectRevert(SiliconSwapAdapter.BadPool.selector);
        adapter.sellSynth(_key(address(weth)), 1e18, 100);
        k = PoolKey({currency0: USDG_AT, currency1: USDG_AT, fee: 3000, tickSpacing: 60, hooks: address(0)});
        vm.expectRevert(SiliconSwapAdapter.BadPool.selector);
        adapter.sellSynth(k, 1e18, 100);

        vm.expectRevert(SiliconSwapAdapter.BadAmount.selector);
        adapter.sellSynth(_key(address(high)), 0, 100);
        uint256 maxV4 = uint256(uint128(type(int128).max));
        vm.expectRevert(abi.encodeWithSelector(SiliconSwapAdapter.AmountTooLarge.selector, maxV4 + 1, maxV4));
        adapter.sellSynth(_key(address(high)), maxV4 + 1, 100);
        vm.expectRevert(SiliconSwapAdapter.BadAmount.selector);
        adapter.sellUsdg(0, 100);
    }

    function test_only_the_pool_manager_calls_back() public {
        vm.expectRevert(SiliconSwapAdapter.NotPoolManager.selector);
        adapter.unlockCallback(abi.encode(_key(address(high)), false, uint256(1e18)));
    }

    function test_refuses_a_sale_that_returns_no_usdg() public {
        pm.set(0, 1, 10_000);
        high.mint(caller, 1e18);
        vm.startPrank(caller);
        high.approve(address(adapter), 1e18);
        vm.expectRevert(SiliconSwapAdapter.NoUsdgOut.selector);
        adapter.sellSynth(_key(address(high)), 1e18, 100);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- through the fee router

    /// The fee router converts its fee synth and USDG through the adapter once the adapter's 24
    /// hours as a target have passed; the WETH arrives at the router, which counts it against the
    /// keeper's minimum, and neither the router nor the adapter keeps an allowance.
    function test_the_fee_router_converts_through_the_adapter() public {
        SiliconFeeRouter feeRouter = new SiliconFeeRouter(IWETH(address(weth)));
        address keeper = makeAddr("keeper");
        feeRouter.setKeeper(keeper);
        feeRouter.queueTarget(address(adapter), true);
        high.mint(address(feeRouter), 3e18);
        usdg.mint(address(feeRouter), 2_000e6);
        bytes memory sellSynth = abi.encodeCall(SiliconSwapAdapter.sellSynth, (_key(address(high)), 3e18, 100));

        vm.prank(keeper);
        vm.expectRevert(SiliconFeeRouter.BadTarget.selector);
        feeRouter.convert(address(high), address(adapter), sellSynth, 3e18, 0);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(SiliconFeeRouter.InsufficientOutput.selector, 0.075e18, 0.075e18 + 1));
        feeRouter.convert(address(high), address(adapter), sellSynth, 3e18, 0.075e18 + 1);

        vm.prank(keeper);
        assertEq(feeRouter.convert(address(high), address(adapter), sellSynth, 3e18, 0.075e18), 0.075e18);
        vm.prank(keeper);
        assertEq(
            feeRouter.convert(
                address(usdg),
                address(adapter),
                abi.encodeCall(SiliconSwapAdapter.sellUsdg, (2_000e6, 100)),
                2_000e6,
                0.5e18
            ),
            0.5e18
        );
        assertEq(weth.balanceOf(address(feeRouter)), 0.575e18);
        assertEq(high.balanceOf(address(feeRouter)), 0);
        assertEq(usdg.balanceOf(address(feeRouter)), 0);
        assertEq(high.allowance(address(feeRouter), address(adapter)), 0);
        assertEq(usdg.allowance(address(feeRouter), address(adapter)), 0);
        _assertNothingLeft();
    }
}
