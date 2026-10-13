// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {WeightRegistry} from "../../src/WeightRegistry.sol";
import {Reserve} from "../../src/Reserve.sol";
import {Staking} from "../../src/Staking.sol";
import {GatewaySettlement} from "../../src/GatewaySettlement.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IKyzn} from "../../src/interfaces/IKyzn.sol";
import {IRotationState} from "../../src/interfaces/IRotationState.sol";
import {IReserveView} from "../../src/interfaces/IReserveView.sol";
import {IStockToken} from "../../src/interfaces/IStockToken.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";

interface IUniswapV2PairLike {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
}

interface ISwapRouter02 {
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

interface IQuoterV2 {
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

/// The contracts against real Robinhood Chain mainnet state: Uniswap v2 Factory and Router02,
/// WETH, the NVDA stock token, Uniswap v3 and the Chainlink feeds. The public RPC keeps
/// about 20 minutes of history, so this forks the latest block and asserts relationships
/// (exact tax, exact split, the price bound) rather than fixed amounts.
contract RobinhoodForkTest is Test {
    KyznToken internal token;
    WeightRegistry internal registry;
    Reserve internal reserve;
    Staking internal staking;
    GatewaySettlement internal gateway;
    IUniswapV2Router02 internal router = IUniswapV2Router02(RH.UNISWAP_V2_ROUTER);

    address internal dev = makeAddr("dev");
    address internal host = makeAddr("host");
    address internal operator = makeAddr("operator");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public {
        vm.createSelectFork("robinhood");
        token = new KyznToken(router, dev);
        registry = new WeightRegistry();
        Reserve.AssetConfig[] memory initial = new Reserve.AssetConfig[](2);
        initial[0] = Reserve.AssetConfig({token: RH.NVDA, feed: RH.NVDA_USD, stage: 0});
        initial[1] = Reserve.AssetConfig({token: RH.AMD, feed: RH.AMD_USD, stage: 0});
        reserve = new Reserve(
            IKyzn(address(token)), IWETH(RH.WETH), RH.ETH_USD_FEED, IRotationState(address(registry)), initial
        );
        reserve.setKeeper(keeper);
        staking = new Staking(IERC20(address(token)), router, IReserveView(address(reserve)), RH.NVDA, RH.AMD);
        gateway = new GatewaySettlement(IKyzn(address(token)), router, host);
        gateway.setOperator(operator);
        token.setProtocolAddresses(address(reserve), address(staking), address(gateway));

        token.transfer(alice, 20_000_000e18);
        token.approve(address(router), 900_000_000e18);
        router.addLiquidityETH{value: 2 ether}(
            address(token), 900_000_000e18, 900_000_000e18, 2 ether, address(this), block.timestamp
        );
        vm.warp(block.timestamp + 31 minutes);
        token.lowerTax(400, 400); // the launch taxes lowered to 4%, as the launch runbook does
        token.removeMaxWallet();
    }

    receive() external payable {}

    function _path(address from, address to) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = from;
        path[1] = to;
    }

    /// Uniswap v2 output for `amountIn` of `tokenIn` at the pair's current reserves (0.3% fee).
    function _amountOut(uint256 amountIn, address tokenIn) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IUniswapV2PairLike(token.pair()).getReserves();
        bool zeroIn = IUniswapV2PairLike(token.pair()).token0() == tokenIn;
        (uint256 rIn, uint256 rOut) = zeroIn ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 withFee = amountIn * 997;
        return withFee * rOut / (rIn * 1000 + withFee);
    }

    function _buy(address who, uint256 ethIn) internal {
        vm.deal(who, who.balance + ethIn);
        vm.prank(who);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            0, _path(RH.WETH, address(token)), who, block.timestamp
        );
    }

    function _sell(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(router), amount);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, _path(address(token), RH.WETH), who, block.timestamp
        );
        vm.stopPrank();
    }

    /// Re-stamps the real Chainlink answers with the current time, after a warp.
    function _stampFeeds() internal {
        address[3] memory feeds = [RH.ETH_USD_FEED, RH.NVDA_USD, RH.AMD_USD];
        for (uint256 i; i < feeds.length; ++i) {
            (uint80 id, int256 answer,,, uint80 answeredIn) = IAggregatorV3(feeds[i]).latestRoundData();
            vm.mockCall(
                feeds[i],
                abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
                abi.encode(id, answer, block.timestamp, block.timestamp, answeredIn)
            );
        }
    }

    function _nextWindow(uint256 timestamp) internal pure returns (uint256) {
        while (!PriceLib.inPurchaseWindow(timestamp)) timestamp += 30 minutes;
        return timestamp;
    }

    /// Pauses every Robinhood Stock Token the way the issuer does (SPEC 3.2a): the tokens read
    /// their paused state from the beacon they share (RH.STOCK_BEACON), so mocking the beacon's
    /// paused() makes each real token report paused and its real transfer() revert, with no mock
    /// on the tokens themselves (verified on a live fork, 26 September 2026). No per-token pauser
    /// exists on chain to prank: the proxies' owner() and DEFAULT_ADMIN_ROLE() revert, and no
    /// RoleGranted event was ever emitted. Unpausing clears every mock on this fork, so a test
    /// that also stamps feeds must stamp them again after unpausing.
    function _setStockTokensPaused(bool value) internal {
        if (value) {
            vm.mockCall(RH.STOCK_BEACON, abi.encodeWithSignature("paused()"), abi.encode(true));
        } else {
            vm.clearMockedCalls();
        }
        assertEq(IStockToken(RH.NVDA).paused(), value);
        assertEq(IStockToken(RH.AMD).paused(), value);
    }

    function test_pair_lives_on_the_real_factory() public view {
        assertEq(IUniswapV2Factory(RH.UNISWAP_V2_FACTORY).getPair(address(token), RH.WETH), token.pair());
        assertEq(token.balanceOf(token.pair()), 900_000_000e18);
    }

    function test_real_buy_pays_exactly_4_percent() public {
        uint256 gross = _amountOut(0.01 ether, RH.WETH);
        _buy(bob, 0.01 ether);
        assertEq(token.balanceOf(bob), gross - gross * 400 / 10_000);
        assertEq(token.balanceOf(address(token)), gross * 400 / 10_000);
    }

    function test_real_sell_swaps_the_tax_and_splits_2_1_1() public {
        _buy(bob, 0.05 ether);
        uint256 pending = token.balanceOf(address(token));
        assertGe(pending, token.swapThreshold());

        vm.recordLogs();
        _sell(alice, 1_000_000e18);
        uint256 sold;
        uint256 eth;
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(token) && logs[i].topics[0] == KyznToken.TaxSwapped.selector) {
                (sold, eth) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
        assertEq(sold, Math.min(pending, 1_000_000e18));
        assertGt(eth, 0);
        assertEq(address(reserve).balance, eth / 2);
        assertEq(address(staking).balance, eth / 4);
        assertEq(token.heldEth(dev), eth - eth / 2 - eth / 4); // held for the development wallet
        assertEq(token.balanceOf(address(token)), pending - sold + 1_000_000e18 * 400 / 10_000);
    }

    function test_real_compound_is_untaxed() public {
        vm.startPrank(alice);
        token.approve(address(staking), 10_000_000e18);
        staking.stake(10_000_000e18);
        vm.stopPrank();
        // As the tax share arrives: Staking takes ETH from the token only.
        vm.deal(address(token), address(token).balance + 0.01 ether);
        vm.prank(address(token));
        (bool ok,) = address(staking).call{value: 0.01 ether}("");
        assertTrue(ok);
        staking.notifyRewards();
        vm.warp(block.timestamp + 24 hours);
        uint256 reward = staking.earned(alice);
        uint256 expected = _amountOut(reward, RH.WETH); // no 4% taken
        uint256 taxBefore = token.balanceOf(address(token));
        vm.prank(alice);
        uint256 added = staking.claimCompound(0);
        assertEq(added, expected);
        assertEq(staking.stakedOf(alice), 10_000_000e18 + added);
        assertEq(token.balanceOf(address(token)), taxBefore);
    }

    function test_real_gateway_settlement() public {
        token.transfer(address(gateway), 1_100_000e18);
        uint256 expected = _amountOut(1_000_000e18, address(token)); // untaxed sale
        uint256 supply = token.totalSupply();
        vm.prank(operator);
        uint256 eth = gateway.settle(1_000_000e18, 100_000e18, 0);
        assertEq(eth, expected);
        assertEq(host.balance, expected);
        assertEq(token.totalSupply(), supply - 100_000e18);
        assertEq(token.balanceOf(address(token)), 0);
    }

    /// Buys NVDA through Uniswap v3 (WETH/NVDA 0.05% pool). If the live pool sits more than
    /// 1.5% below the Chainlink-implied price, the Reserve must refuse with PriceBound.
    function test_real_reserve_buys_nvda_under_the_price_bound() public {
        reserve.queueTarget(RH.UNISWAP_V3_SWAP_ROUTER_02, true);
        vm.warp(_nextWindow(block.timestamp + 24 hours));
        _stampFeeds();
        vm.deal(address(reserve), 1 ether);

        uint256 ethIn = 0.2 ether;
        (uint256 quote,,,) = IQuoterV2(RH.UNISWAP_V3_QUOTER_V2)
            .quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams(RH.WETH, RH.NVDA, ethIn, 500, 0));
        uint256 ethPrice = PriceLib.fresh(RH.ETH_USD_FEED, 8, 24 hours);
        uint256 nvdaPrice = PriceLib.fresh(RH.NVDA_USD, 8, 24 hours);
        uint256 bound = Math.mulDiv(ethIn, ethPrice, nvdaPrice) * 9_850 / 10_000;

        bytes memory data = abi.encodeCall(
            ISwapRouter02.exactInputSingle,
            (ISwapRouter02.ExactInputSingleParams(RH.WETH, RH.NVDA, 500, address(reserve), ethIn, 0, 0))
        );
        if (quote < bound) vm.expectRevert(abi.encodeWithSelector(Reserve.PriceBound.selector, quote, bound));
        vm.prank(keeper);
        uint256 got = reserve.buy(RH.NVDA, RH.UNISWAP_V3_SWAP_ROUTER_02, data, ethIn, 0);
        if (quote >= bound) {
            assertEq(got, quote);
            assertEq(IERC20(RH.NVDA).balanceOf(address(reserve)), quote);
            assertEq(address(reserve).balance, 1 ether - ethIn);
        }
    }

    /// Ports the reviewer's SwapRouter02 sale probe. A published rotation with executesAt equal
    /// to the publish time is executed immediately (registry.hasExecuted()), satisfying the new
    /// registry rules (each weight at most 5,000 bps, design (4,000) plus power (1,000) at most
    /// 5,000, executing well within the 31-day horizon). NVDA and AMD are both the design stage
    /// (SPEC 3.2a); the Reserve holds only NVDA and no ETH or AMD, so design trivially holds
    /// 100% of Reserve value, above the 50% cap, leaving room to sell. A Reserve sale through the
    /// real SwapRouter02 pays WETH, which the Reserve unwraps through the real WETH into its
    /// empty receive(), within the Chainlink price bound.
    function test_real_reserve_sells_through_swaprouter02() public {
        reserve.queueTarget(RH.UNISWAP_V3_SWAP_ROUTER_02, true);
        uint16[5] memory w = [uint16(4_000), 2_000, 2_000, 1_000, 1_000];
        registry.publish(w, keccak256("memo"), "uri", uint64(block.timestamp));
        assertTrue(registry.hasExecuted());
        vm.warp(_nextWindow(block.timestamp + 24 hours));
        _stampFeeds();
        deal(RH.NVDA, address(reserve), 100e18);

        uint256 amountIn = 2e18;
        (uint256 quote,,,) = IQuoterV2(RH.UNISWAP_V3_QUOTER_V2)
            .quoteExactInputSingle(IQuoterV2.QuoteExactInputSingleParams(RH.NVDA, RH.WETH, amountIn, 500, 0));
        uint256 ethPrice = PriceLib.fresh(RH.ETH_USD_FEED, 8, 24 hours);
        uint256 nvdaPrice = PriceLib.fresh(RH.NVDA_USD, 8, 24 hours);
        uint256 bound = Math.mulDiv(amountIn, nvdaPrice, ethPrice) * 9_850 / 10_000;

        bytes memory data = abi.encodeCall(
            ISwapRouter02.exactInputSingle,
            (ISwapRouter02.ExactInputSingleParams(RH.NVDA, RH.WETH, 500, address(reserve), amountIn, 0, 0))
        );
        if (quote < bound) vm.expectRevert(abi.encodeWithSelector(Reserve.PriceBound.selector, quote, bound));
        vm.prank(keeper);
        uint256 got = reserve.sell(RH.NVDA, RH.UNISWAP_V3_SWAP_ROUTER_02, data, amountIn, 0);
        if (quote >= bound) {
            assertEq(got, quote);
            assertEq(address(reserve).balance, quote); // unwrapped through the real WETH
            assertEq(IERC20(RH.WETH).balanceOf(address(reserve)), 0);
            assertEq(IERC20(RH.NVDA).balanceOf(address(reserve)), 100e18 - amountIn);
        }
    }

    function test_real_redemption_pays_nvda_and_eth() public {
        deal(RH.NVDA, address(reserve), 10e18);
        vm.deal(address(reserve), 1 ether);
        uint256 supply = token.totalSupply();
        uint256 nvdaOut = Math.mulDiv(10e18, 1_000_000e18 * 9_800, supply * 10_000);
        uint256 ethOut = Math.mulDiv(1 ether, 1_000_000e18 * 9_800, supply * 10_000);
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        token.approve(address(reserve), 1_000_000e18);
        reserve.redeem(1_000_000e18);
        vm.stopPrank();
        assertEq(IERC20(RH.NVDA).balanceOf(alice), nvdaOut);
        assertEq(alice.balance - ethBefore, ethOut);
        assertEq(token.totalSupply(), supply - 1_000_000e18);
    }

    /// The issuer can pause the stock tokens at any time, and one action on their shared beacon
    /// pauses all of them (SPEC 3.2a). Redemption must still pay the ETH at once and record each
    /// stock-token share as a claim (SPEC 3.2), collectible once the tokens unpause.
    function test_real_paused_stock_tokens_become_claims() public {
        deal(RH.NVDA, address(reserve), 10e18);
        deal(RH.AMD, address(reserve), 20e18);
        vm.deal(address(reserve), 1 ether);
        _setStockTokensPaused(true);

        uint256 supply = token.totalSupply();
        uint256 redeemAmount = 1_000_000e18;
        uint256 nvdaShare = Math.mulDiv(10e18, redeemAmount * 9_800, supply * 10_000);
        uint256 amdShare = Math.mulDiv(20e18, redeemAmount * 9_800, supply * 10_000);
        uint256 ethShare = Math.mulDiv(1 ether, redeemAmount * 9_800, supply * 10_000);
        uint256 ethBefore = alice.balance;

        vm.startPrank(alice);
        token.approve(address(reserve), redeemAmount);
        reserve.redeem(redeemAmount);
        vm.stopPrank();

        // ETH pays out at once; both paused stock-token shares are withheld as claims.
        assertEq(alice.balance - ethBefore, ethShare);
        assertEq(IERC20(RH.NVDA).balanceOf(alice), 0);
        assertEq(IERC20(RH.AMD).balanceOf(alice), 0);
        assertEq(reserve.claims(RH.NVDA, alice), nvdaShare);
        assertEq(reserve.claims(RH.AMD, alice), amdShare);
        assertEq(reserve.totalClaims(RH.NVDA), nvdaShare);
        assertEq(reserve.totalClaims(RH.AMD), amdShare);
        assertEq(token.totalSupply(), supply - redeemAmount);

        // Once the tokens unpause, the recorded claims pay.
        _setStockTokensPaused(false);
        vm.startPrank(alice);
        reserve.claim(RH.NVDA);
        reserve.claim(RH.AMD);
        vm.stopPrank();
        assertEq(IERC20(RH.NVDA).balanceOf(alice), nvdaShare);
        assertEq(IERC20(RH.AMD).balanceOf(alice), amdShare);
        assertEq(reserve.totalClaims(RH.NVDA), 0);
        assertEq(reserve.totalClaims(RH.AMD), 0);
    }
}
