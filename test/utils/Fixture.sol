// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {WeightRegistry} from "../../src/WeightRegistry.sol";
import {Reserve} from "../../src/Reserve.sol";
import {Staking} from "../../src/Staking.sol";
import {GatewaySettlement} from "../../src/GatewaySettlement.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IKyzn} from "../../src/interfaces/IKyzn.sol";
import {IRotationState} from "../../src/interfaces/IRotationState.sol";
import {IReserveView} from "../../src/interfaces/IReserveView.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockFeed} from "../mocks/MockFeed.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {MockUniswapV2Factory, MockUniswapV2Router} from "../mocks/MockUniswapV2.sol";
import {PayableProtocolStub} from "../mocks/ProtocolStub.sol";

/// Every Kyzen Network contract on the mock Uniswap v2, launch liquidity added. Trading is open
/// from deployment (the token has no switch), at the launch taxes (5% on buys, 10% on sells) with
/// the 2% max wallet on. The test contract is the owner of everything.
/// Mock prices: ETH $2,500 · NVDA $200 · AMD $150 · MU $100 (8-decimal feeds).
abstract contract Fixture is Test {
    uint256 internal constant MONDAY_1400 = 1_790_604_000; // Monday 28 September 2026, 14:00 UTC
    uint256 internal constant LIQUIDITY_TOKENS = 900_000_000e18;

    address internal dev = makeAddr("dev");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal host = makeAddr("host");
    address internal operator = makeAddr("operator");

    MockWETH internal weth;
    MockUniswapV2Factory internal factory;
    MockUniswapV2Router internal router;
    MockFeed internal ethUsd;
    MockStockToken internal nvda;
    MockStockToken internal amd;
    MockStockToken internal mu;
    MockFeed internal nvdaFeed;
    MockFeed internal amdFeed;
    MockFeed internal muFeed;

    KyznToken internal token;
    address internal pair;
    WeightRegistry internal registry;
    Reserve internal reserve;
    Staking internal staking;
    GatewaySettlement internal gateway;

    function setUp() public virtual {
        vm.warp(MONDAY_1400);
        weth = new MockWETH();
        factory = new MockUniswapV2Factory();
        router = new MockUniswapV2Router(address(factory), address(weth));
        factory.setRouter(address(router));
        vm.deal(address(router), 10_000 ether);

        ethUsd = new MockFeed(8, 2_500e8);
        nvda = new MockStockToken("NVDA");
        amd = new MockStockToken("AMD");
        mu = new MockStockToken("MU");
        nvdaFeed = new MockFeed(8, 200e8);
        amdFeed = new MockFeed(8, 150e8);
        muFeed = new MockFeed(8, 100e8);

        token = new KyznToken(IUniswapV2Router02(address(router)), dev);
        pair = token.pair();

        registry = new WeightRegistry();
        Reserve.AssetConfig[] memory initial = new Reserve.AssetConfig[](3);
        initial[0] = Reserve.AssetConfig({token: address(nvda), feed: address(nvdaFeed), stage: 0}); // design
        initial[1] = Reserve.AssetConfig({token: address(amd), feed: address(amdFeed), stage: 0}); // design
        initial[2] = Reserve.AssetConfig({token: address(mu), feed: address(muFeed), stage: 1}); // memory
        reserve = new Reserve(
            IKyzn(address(token)), IWETH(address(weth)), address(ethUsd), IRotationState(address(registry)), initial
        );
        reserve.setKeeper(keeper);

        staking = new Staking(
            IERC20(address(token)),
            IUniswapV2Router02(address(router)),
            IReserveView(address(reserve)),
            address(nvda),
            address(amd)
        );

        gateway = new GatewaySettlement(IKyzn(address(token)), IUniswapV2Router02(address(router)), host);
        gateway.setOperator(operator);

        token.setProtocolAddresses(address(reserve), address(staking), address(gateway));
        token.approve(address(router), LIQUIDITY_TOKENS);
        router.addLiquidityETH{value: 2 ether}(address(token), LIQUIDITY_TOKENS, 0, 0, address(this), block.timestamp);
    }

    receive() external payable {}

    /// After the launch the owner lowers both taxes to 4% (SPEC 3.1). Trading is open from
    /// deployment; the launch taxes themselves are tested in KyznTokenLaunchTax.t.sol.
    function _launch() internal {
        token.lowerTax(400, 400);
    }

    /// Lists an asset now, as if its 24-hour wait had passed, without moving the test's clock.
    function _listNow(address token_, address feed, uint8 stage) internal {
        uint256 t = block.timestamp;
        reserve.addAsset(token_, feed, stage);
        vm.warp(t + reserve.TARGET_DELAY());
        reserve.listAsset(token_);
        vm.warp(t);
    }

    /// ETH into Staking as the token's tax split sends it: Staking takes ETH from the token only.
    function _taxEthToStaking(uint256 amount) internal {
        vm.deal(address(token), address(token).balance + amount);
        vm.prank(address(token));
        (bool ok,) = address(staking).call{value: amount}("");
        require(ok, "fund");
    }

    /// Sets every mock feed's update time to now, at the fixture prices.
    function _refreshFeeds() internal {
        ethUsd.set(2_500e8, block.timestamp);
        nvdaFeed.set(200e8, block.timestamp);
        amdFeed.set(150e8, block.timestamp);
        muFeed.set(100e8, block.timestamp);
    }

    /// A second Reserve, Staking and Gateway for `t` that `t.setProtocolAddresses` accepts (each
    /// reads back `t`'s addresses as the real contracts do). The Reserve and Staking stand-ins take,
    /// refuse or burn the gas of the ETH sent to them, as set.
    function _payableStubs(KyznToken t, PayableProtocolStub.Mode reserveMode, PayableProtocolStub.Mode stakingMode)
        internal
        returns (PayableProtocolStub r, PayableProtocolStub s, address g)
    {
        address router_ = address(t.router());
        r = new PayableProtocolStub(address(t), t.weth(), address(0), address(0), reserveMode);
        s = new PayableProtocolStub(address(t), address(0), address(r), router_, stakingMode);
        g = address(
            new PayableProtocolStub(address(t), address(0), address(0), router_, PayableProtocolStub.Mode.Accept)
        );
    }

    function _path(address from, address to) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = from;
        path[1] = to;
    }

    function _buy(address who, uint256 ethIn) internal returns (uint256 received) {
        vm.deal(who, who.balance + ethIn);
        uint256 before = token.balanceOf(who);
        vm.prank(who);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            0, _path(address(weth), address(token)), who, block.timestamp
        );
        received = token.balanceOf(who) - before;
    }

    function _sell(address who, uint256 amount) internal returns (uint256 ethOut) {
        uint256 before = who.balance;
        vm.startPrank(who);
        token.approve(address(router), amount);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, _path(address(token), address(weth)), who, block.timestamp
        );
        vm.stopPrank();
        ethOut = who.balance - before;
    }
}
