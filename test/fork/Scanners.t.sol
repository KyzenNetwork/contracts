// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {WeightRegistry} from "../../src/WeightRegistry.sol";
import {Reserve} from "../../src/Reserve.sol";
import {Staking} from "../../src/Staking.sol";
import {GatewaySettlement} from "../../src/GatewaySettlement.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IKyzn} from "../../src/interfaces/IKyzn.sol";
import {IRotationState} from "../../src/interfaces/IRotationState.sol";
import {IReserveView} from "../../src/interfaces/IReserveView.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";

interface IPairLike {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}

/// A development wallet that refuses ETH, to show its refusal never blocks a sell.
contract RefusesEth {
    receive() external payable {
        revert("no");
    }
}

/// What token scanners (honeypot simulators, contract scanners) do to a new token, against
/// real Robinhood Chain mainnet state with the launch pool (900,000,000 $KYZN and 2 ETH):
/// fresh wallets buy and then sell through Uniswap v2 Router02, sell their whole balance,
/// sell straight into the pair as aggregators do, and transfer between wallets. Every sell
/// must succeed and every taxed trade must pay exactly the tax set (5% on buys and 10% on sells
/// at launch, 4% once lowered), whatever the owner sets afterwards.
contract ScannersForkTest is Test {
    KyznToken internal token;
    Reserve internal reserve;
    Staking internal staking;
    GatewaySettlement internal gateway;
    IUniswapV2Router02 internal router = IUniswapV2Router02(RH.UNISWAP_V2_ROUTER);

    address internal dev = makeAddr("dev");
    address internal host = makeAddr("host");

    function setUp() public {
        vm.createSelectFork("robinhood");
        token = new KyznToken(router, dev);
        WeightRegistry registry = new WeightRegistry();
        Reserve.AssetConfig[] memory initial = new Reserve.AssetConfig[](2);
        initial[0] = Reserve.AssetConfig({token: RH.NVDA, feed: RH.NVDA_USD, stage: 0});
        initial[1] = Reserve.AssetConfig({token: RH.AMD, feed: RH.AMD_USD, stage: 0});
        reserve = new Reserve(
            IKyzn(address(token)), IWETH(RH.WETH), RH.ETH_USD_FEED, IRotationState(address(registry)), initial
        );
        staking = new Staking(IERC20(address(token)), router, IReserveView(address(reserve)), RH.NVDA, RH.AMD);
        gateway = new GatewaySettlement(IKyzn(address(token)), router, host);
        token.setProtocolAddresses(address(reserve), address(staking), address(gateway));
        token.approve(address(router), 900_000_000e18);
        router.addLiquidityETH{value: 2 ether}(
            address(token), 900_000_000e18, 900_000_000e18, 2 ether, address(this), block.timestamp
        );
        // Trading is open from deployment, at the launch taxes (5% on buys, 10% on sells); the tests below lower both
        // to 4% first, as the owner does, except those that check the launch phase itself.
    }

    receive() external payable {}

    function _atFourPercent() internal {
        token.lowerTax(400, 400);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _buy(address who, uint256 eth) internal returns (uint256 got) {
        vm.deal(who, who.balance + eth);
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: eth}(0, _path(RH.WETH, address(token)), who, block.timestamp);
        got = token.balanceOf(who) - before;
    }

    function _sell(address who, uint256 amount) internal returns (uint256 eth) {
        vm.startPrank(who);
        token.approve(address(router), amount);
        uint256 before = who.balance;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, _path(address(token), RH.WETH), who, block.timestamp);
        vm.stopPrank();
        eth = who.balance - before;
    }

    /// Uniswap v2 output at the pair's reserves, 0.3% fee.
    function _out(uint256 amountIn, bool kyznIn) internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = IPairLike(token.pair()).getReserves();
        bool kyznIs0 = IPairLike(token.pair()).token0() == address(token);
        (uint256 rIn, uint256 rOut) = kyznIn == kyznIs0 ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
        uint256 withFee = amountIn * 997;
        return withFee * rOut / (rIn * 1000 + withFee);
    }

    function test_a_fresh_wallet_buys_and_sells_its_whole_balance_right_after_trading_opens() public {
        _atFourPercent();
        address scanner = makeAddr("scanner");
        uint256 got = _buy(scanner, 0.01 ether);
        assertGt(got, 0);
        uint256 eth = _sell(scanner, got);
        assertGt(eth, 0);
        assertEq(token.balanceOf(scanner), 0);
    }

    function test_buy_and_sell_tax_measure_exactly_4_percent() public {
        _atFourPercent();
        address scanner = makeAddr("scanner");
        uint256 expectedOut = _out(0.01 ether, false);
        uint256 got = _buy(scanner, 0.01 ether);
        // Buy tax: 4% of what left the pool.
        assertEq(got, expectedOut - expectedOut * 400 / 10_000);
        // Sell tax: the pool receives 96% of the tokens sold.
        uint256 sellIn = got - got * 400 / 10_000;
        uint256 expectedEth = _out(sellIn, true);
        uint256 eth = _sell(scanner, got);
        assertEq(eth, expectedEth);
    }

    function test_a_sell_that_starts_the_tax_swap_still_pays_the_seller() public {
        _atFourPercent();
        // Others' buys bring the collected tax past the swap threshold.
        for (uint256 i; i < 6; i++) _buy(makeAddr(string(abi.encode("buyer", i))), 0.01 ether);
        assertGe(token.balanceOf(address(token)), token.swapThreshold());
        address scanner = makeAddr("scanner");
        uint256 got = _buy(scanner, 0.005 ether);
        uint256 eth = _sell(scanner, got);
        assertGt(eth, 0);
        assertEq(token.balanceOf(scanner), 0);
    }

    function test_an_aggregator_style_sell_into_the_pair_is_paid_in_full() public {
        _atFourPercent();
        for (uint256 i; i < 6; i++) _buy(makeAddr(string(abi.encode("buyer", i))), 0.01 ether);
        address agg = makeAddr("aggregator");
        uint256 got = _buy(agg, 0.005 ether);
        IPairLike pair = IPairLike(token.pair());
        // Transfer into the pair (taxed 4%, and the tax swap runs first), then swap what arrived.
        vm.prank(agg);
        token.transfer(address(pair), got);
        (uint112 r0, uint112 r1,) = pair.getReserves();
        bool kyznIs0 = pair.token0() == address(token);
        uint256 arrived = token.balanceOf(address(pair)) - (kyznIs0 ? uint256(r0) : uint256(r1));
        assertEq(arrived, got - got * 400 / 10_000);
        uint256 out = _out(arrived, true);
        uint256 wethBefore = IERC20(RH.WETH).balanceOf(agg);
        vm.prank(agg);
        pair.swap(kyznIs0 ? 0 : out, kyznIs0 ? out : 0, agg, "");
        assertEq(IERC20(RH.WETH).balanceOf(agg) - wethBefore, out);
    }

    function test_wallet_to_wallet_transfers_are_untaxed_and_transferFrom_works() public {
        _atFourPercent();
        vm.warp(block.timestamp + 31 minutes);
        token.removeMaxWallet();
        address a = makeAddr("a");
        address b = makeAddr("b");
        uint256 got = _buy(a, 0.01 ether);
        vm.prank(a);
        token.transfer(b, got / 2);
        assertEq(token.balanceOf(b), got / 2);
        vm.prank(b);
        token.approve(a, got / 4);
        vm.prank(a);
        token.transferFrom(b, a, got / 4);
        assertEq(token.balanceOf(b), got / 2 - got / 4);
    }

    function test_nothing_the_owner_can_set_after_launch_stops_a_sell() public {
        vm.warp(block.timestamp + 31 minutes);
        token.removeMaxWallet();
        for (uint256 i; i < 6; i++) _buy(makeAddr(string(abi.encode("buyer", i))), 0.01 ether);
        // Every owner power left after launch, at its most hostile setting.
        token.setDevWallet(address(new RefusesEth()));
        token.setSwapThreshold(token.MIN_SWAP_THRESHOLD());
        token.lowerTax(token.MIN_TAX_BPS(), token.MIN_TAX_BPS());
        address scanner = makeAddr("scanner");
        uint256 got = _buy(scanner, 0.01 ether);
        uint256 eth = _sell(scanner, got);
        assertGt(eth, 0);
        token.setSwapThreshold(token.MAX_SWAP_THRESHOLD());
        got = _buy(scanner, 0.01 ether);
        assertGt(_sell(scanner, got), 0);
    }

    function test_during_the_launch_taxes_a_fresh_wallet_buys_and_sells_its_whole_balance() public {
        address scanner = makeAddr("scanner");
        uint256 expectedOut = _out(0.01 ether, false);
        uint256 got = _buy(scanner, 0.01 ether);
        assertEq(got, expectedOut - expectedOut * 500 / 10_000); // 5% on the buy, 10% on the sell
        uint256 sellIn = got - got / 10;
        uint256 expectedEth = _out(sellIn, true);
        assertEq(_sell(scanner, got), expectedEth);
        assertEq(token.balanceOf(scanner), 0);
    }

    function test_after_lowering_to_4_percent_and_renouncing_trading_works_and_the_owner_is_zero() public {
        for (uint256 i; i < 6; i++) _buy(makeAddr(string(abi.encode("buyer", i))), 0.01 ether);
        _atFourPercent();
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
        address scanner = makeAddr("scanner");
        uint256 got = _buy(scanner, 0.01 ether);
        assertGt(_sell(scanner, got), 0);
        assertEq(token.balanceOf(scanner), 0);
        assertEq(token.buyTaxBps(), 400);
        assertEq(token.sellTaxBps(), 400);
    }

    function test_the_owner_cannot_raise_the_tax_or_mint() public {
        uint256 buyBps = token.buyTaxBps();
        uint256 sellBps = token.sellTaxBps();
        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(buyBps + 1, sellBps);
        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(buyBps, sellBps + 1);
        assertEq(token.totalSupply(), 1_000_000_000e18);
    }
}
