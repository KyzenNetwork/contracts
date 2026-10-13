// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {KyzenLaunch} from "../script/KyzenLaunch.sol";
import {KyzenMainnetLaunch, WrongChain, mainnetSetup} from "../script/KyzenMainnetLaunch.sol";
import {Months} from "../script/lib/Months.sol";
import {RobinhoodChain} from "../script/RobinhoodChain.sol";
import {TestnetSablierLockup} from "../script/testnet/TestnetSablierLockup.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {RejectingReceiver} from "./mocks/Receivers.sol";

/// Router02's liquidity removal, which the token's interface leaves out.
interface IRouterRemoveLiquidity {
    function removeLiquidityETH(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountToken, uint256 amountEth);

    function removeLiquidityETHSupportingFeeOnTransferTokens(
        address token,
        uint256 liquidity,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountEth);
}

interface ILaunchTestPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address) external view returns (uint256);
    function sync() external;
}

/// The one-transaction launch (script/KyzenLaunch.sol) offline: the official Uniswap v2 factory
/// and Router02 (the unmodified build in external/uniswap-v2), a stand-in WETH, and the testnet
/// stand-in for Sablier (script/testnet). test/fork/KyzenLaunch.t.sol runs the mainnet launch
/// against Robinhood Chain's real Uniswap v2 and Sablier.
contract KyzenLaunchTest is Test {
    uint256 internal constant LIQUIDITY_ETH = 2 ether;
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;
    address internal constant SWAP_TARGET = address(0x5a9);

    MockWETH internal weth;
    address internal factory;
    IUniswapV2Router02 internal router;
    TestnetSablierLockup internal sablier;
    RobinhoodChain.Asset[] internal assetList;
    address internal nvda;
    address internal amd;
    address internal ethUsd;

    address internal owner = makeAddr("owner");
    address internal dev = makeAddr("dev");
    address internal team = makeAddr("team");
    address internal host = makeAddr("host");
    address internal keeper = makeAddr("keeper");
    address internal operator = makeAddr("operator");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        weth = new MockWETH();
        factory = deployCode("external/uniswap-v2/UniswapV2Factory.json", abi.encode(address(this)));
        router = IUniswapV2Router02(
            deployCode("external/uniswap-v2/UniswapV2Router02.json", abi.encode(factory, address(weth)))
        );
        sablier = new TestnetSablierLockup();
        ethUsd = address(new MockFeed(8, 2_500e8));
        nvda = address(new MockStockToken("NVDA"));
        amd = address(new MockStockToken("AMD"));
        address mu = address(new MockStockToken("MU"));
        assetList.push(RobinhoodChain.Asset({token: nvda, feed: address(new MockFeed(8, 200e8)), stage: 0}));
        assetList.push(RobinhoodChain.Asset({token: amd, feed: address(new MockFeed(8, 150e8)), stage: 0}));
        assetList.push(RobinhoodChain.Asset({token: mu, feed: address(new MockFeed(8, 100e8)), stage: 1}));
        vm.deal(owner, 10 ether);
        vm.deal(buyer, 10 ether);
    }

    function _setup() internal view returns (KyzenLaunch.Setup memory s) {
        s.router = router;
        s.ethUsdFeed = ethUsd;
        s.assets = assetList;
        s.equityAssetA = nvda;
        s.equityAssetB = amd;
        s.swapTarget = SWAP_TARGET;
        s.sablier = sablier;
        s.liquidityEth = LIQUIDITY_ETH;
        s.devWallet = dev;
        s.teamWallet = team;
        s.hostPayout = host;
        s.keeper = keeper;
        s.operator = operator;
    }

    function _launch(KyzenLaunch.Setup memory s, uint256 value) internal returns (KyzenLaunch) {
        vm.prank(owner);
        return new KyzenLaunch{value: value}(s);
    }

    function _reserves(KyzenLaunch l) internal view returns (uint256 kyzn, uint256 eth) {
        ILaunchTestPair p = ILaunchTestPair(l.pair());
        (uint112 r0, uint112 r1,) = p.getReserves();
        (kyzn, eth) = p.token0() == address(l.token()) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    // ---------------------------------------------------------------- the launch

    function test_one_deployment_launches_everything() public {
        uint256 start = block.timestamp;
        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        KyznToken token = l.token();
        address pair = l.pair();

        // The token: wired, liquid, trading at the launch taxes (5% on buys, 10% on sells), with the
        // 2% max wallet on and the launch swap threshold.
        assertEq(pair, IUniswapV2Factory(factory).getPair(address(token), address(weth)));
        assertEq(token.devWallet(), dev);
        assertEq(token.reserve(), address(l.reserve()));
        assertEq(token.staking(), address(l.staking()));
        assertEq(token.gateway(), address(l.gateway()));
        assertEq(token.launchedAt(), start);
        assertEq(token.buyTaxBps(), 500);
        assertEq(token.sellTaxBps(), 1_000);
        assertTrue(token.maxWalletActive());
        assertEq(token.swapThreshold(), 500_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18);

        // The liquidity: 900,000,000 $KYZN and 2 ETH, every LP token minted to the owner, who locks
        // them on UNCX by hand.
        (uint256 kyznReserve, uint256 ethReserve) = _reserves(l);
        assertEq(kyznReserve, 900_000_000e18);
        assertEq(ethReserve, LIQUIDITY_ETH);
        uint256 lp = Math.sqrt(900_000_000e18 * LIQUIDITY_ETH) - MINIMUM_LIQUIDITY;
        assertEq(ILaunchTestPair(pair).totalSupply(), lp + MINIMUM_LIQUIDITY);
        assertEq(l.lpTokens(), lp);
        assertEq(ILaunchTestPair(pair).balanceOf(owner), lp);

        // The team stream: 100,000,000 $KYZN, 6-month cliff, linear to 18 months.
        uint256 id = l.streamId();
        assertEq(token.balanceOf(address(sablier)), 100_000_000e18);
        assertEq(sablier.getRecipient(id), team);
        assertEq(sablier.getSender(id), owner);
        assertEq(uint256(sablier.getDepositedAmount(id)), 100_000_000e18);
        assertEq(uint256(sablier.getCliffTime(id)), Months.add(start, 6));
        assertEq(uint256(sablier.getEndTime(id)), Months.add(start, 18));
        assertFalse(sablier.isCancelable(id));
        assertFalse(sablier.isTransferable(id));

        // The Reserve, Staking and the Gateway.
        assertEq(l.reserve().assetCount(), 3);
        assertEq(l.reserve().assets(0), nvda);
        assertEq(l.reserve().keeper(), keeper);
        assertEq(address(l.reserve().kyzn()), address(token));
        assertEq(address(l.reserve().registry()), address(l.registry()));
        assertFalse(l.reserve().isTargetAllowed(SWAP_TARGET));
        vm.warp(start + 24 hours);
        assertTrue(l.reserve().isTargetAllowed(SWAP_TARGET));
        assertEq(address(l.staking().reserve()), address(l.reserve()));
        assertEq(l.staking().equityAssetA(), nvda);
        assertEq(l.staking().equityAssetB(), amd);
        assertEq(l.staking().feeSource(), address(0)); // only the token sends Staking ETH
        assertFalse(l.staking().equityEnabled()); // chip equity off until counsel review
        assertEq(l.gateway().operator(), operator);
        assertEq(l.gateway().hostPayout(), host);

        // Ownership waits for the deployer to accept it; the launch contract keeps nothing.
        assertEq(token.owner(), address(l));
        assertEq(token.pendingOwner(), owner);
        assertEq(l.registry().pendingOwner(), owner);
        assertEq(l.reserve().pendingOwner(), owner);
        assertEq(l.staking().pendingOwner(), owner);
        assertEq(l.gateway().pendingOwner(), owner);
        assertEq(token.balanceOf(address(l)), 0);
        assertEq(ILaunchTestPair(pair).balanceOf(address(l)), 0);
        assertEq(weth.balanceOf(address(l)), 0);
        assertEq(address(l).balance, 0);
        assertEq(owner.balance, 10 ether - LIQUIDITY_ETH);
    }

    function test_the_launch_event_names_every_address() public {
        vm.recordLogs();
        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.emitter, address(l));
        assertEq(last.topics[0], KyzenLaunch.Launched.selector);
        assertEq(last.topics[1], bytes32(uint256(uint160(owner))));
        (
            address token,
            address pair,
            address registry,
            address reserve,
            address staking,
            address gateway,
            uint256 id,
            uint256 lpTokens
        ) = abi.decode(last.data, (address, address, address, address, address, address, uint256, uint256));
        assertEq(token, address(l.token()));
        assertEq(pair, l.pair());
        assertEq(registry, address(l.registry()));
        assertEq(reserve, address(l.reserve()));
        assertEq(staking, address(l.staking()));
        assertEq(gateway, address(l.gateway()));
        assertEq(id, l.streamId());
        assertEq(lpTokens, l.lpTokens());
    }

    function test_eth_beyond_the_liquidity_is_sent_back() public {
        _launch(_setup(), 3 ether);
        assertEq(owner.balance, 10 ether - LIQUIDITY_ETH);
    }

    /// ETH sent to the launch contract's address before it exists (anyone can) does not block the
    /// launch: it goes back to the deployer with the change.
    function test_eth_sent_ahead_to_the_launch_address_goes_to_the_deployer() public {
        address predicted = vm.computeCreateAddress(owner, vm.getNonce(owner));
        vm.deal(predicted, 1 ether);
        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        assertEq(address(l), predicted);
        assertEq(address(l).balance, 0);
        assertEq(owner.balance, 10 ether - LIQUIDITY_ETH + 1 ether);
    }

    function test_a_buy_and_a_sell_work_at_the_launch_taxes_right_after() public {
        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        KyznToken token = l.token();
        vm.prank(buyer);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(
            0, _path(address(weth), address(token)), buyer, block.timestamp
        );
        uint256 bought = token.balanceOf(buyer);
        uint256 tax = token.balanceOf(address(token));
        assertGt(bought, 0);
        assertEq(tax, (bought + tax) * 500 / 10_000); // 5% of what left the pool

        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        token.approve(address(router), bought);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            bought, 0, _path(address(token), address(weth)), buyer, block.timestamp
        );
        vm.stopPrank();
        assertGt(buyer.balance, ethBefore);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(address(token)), tax + bought * 1_000 / 10_000); // 10% of the sell
    }

    function test_the_deployer_accepts_ownership_then_lowers_the_tax_and_renounces() public {
        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        KyznToken token = l.token();
        vm.startPrank(owner);
        token.acceptOwnership();
        l.registry().acceptOwnership();
        l.reserve().acceptOwnership();
        l.staking().acceptOwnership();
        l.gateway().acceptOwnership();
        token.lowerTax(400, 400);
        token.renounceOwnership();
        vm.stopPrank();
        assertEq(token.owner(), address(0));
        assertEq(token.buyTaxBps(), 400);
        assertEq(token.sellTaxBps(), 400);
        assertEq(l.reserve().owner(), owner);
        assertEq(l.registry().owner(), owner);
        assertEq(l.staking().owner(), owner);
        assertEq(l.gateway().owner(), owner);
    }

    /// A front-runner may pre-create the pair at the token's predicted address and donate WETH to
    /// it. It cannot `sync`, `skim` or `mint` there: each reads the token's balance, and the token
    /// does not exist until the launch, which then adds the liquidity in the same transaction. The
    /// launch succeeds, the donation joins the pool and all the LP goes to the owner.
    function test_a_pre_created_pair_with_donated_weth_does_not_stop_the_launch() public {
        address predictedLaunch = vm.computeCreateAddress(owner, vm.getNonce(owner));
        // A contract's first creation uses nonce 1: the WeightRegistry, then the token.
        address predictedToken = vm.computeCreateAddress(predictedLaunch, 2);
        address pair = IUniswapV2Factory(factory).createPair(predictedToken, address(weth));
        weth.deposit{value: 1 ether}();
        weth.transfer(pair, 1 ether);
        vm.expectRevert();
        ILaunchTestPair(pair).sync();

        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        assertEq(address(l.token()), predictedToken);
        assertEq(l.pair(), pair);
        (uint256 kyznReserve, uint256 ethReserve) = _reserves(l);
        assertEq(kyznReserve, 900_000_000e18);
        assertEq(ethReserve, LIQUIDITY_ETH + 1 ether);
        uint256 lp = Math.sqrt(900_000_000e18 * (LIQUIDITY_ETH + 1 ether)) - MINIMUM_LIQUIDITY;
        assertEq(l.lpTokens(), lp);
        assertEq(ILaunchTestPair(pair).balanceOf(address(l)), 0);
        assertEq(ILaunchTestPair(pair).balanceOf(owner), lp);
    }

    // ---------------------------------------------------------------- the pool, on Router02

    /// A buy above the 2% max wallet reverts inside the pair's transfer, which Uniswap reports as
    /// its own TRANSFER_FAILED; a buy under it goes through, and so does the first once the owner
    /// removes the limit.
    function test_a_buy_above_the_max_wallet_reverts_on_uniswap_v2() public {
        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        KyznToken token = l.token();
        address[] memory path = _path(address(weth), address(token));
        vm.prank(buyer);
        vm.expectRevert(bytes("UniswapV2: TRANSFER_FAILED"));
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.1 ether}(0, path, buyer, block.timestamp);
        assertEq(token.balanceOf(buyer), 0);

        vm.prank(buyer);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.04 ether}(0, path, buyer, block.timestamp);
        assertGt(token.balanceOf(buyer), 0);
        assertLe(token.balanceOf(buyer), token.MAX_WALLET());

        // The limit is what stopped it: with the max wallet removed, the same buy goes through.
        vm.startPrank(owner);
        token.acceptOwnership();
        token.removeMaxWallet();
        vm.stopPrank();
        vm.prank(buyer);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.1 ether}(0, path, buyer, block.timestamp);
        assertGt(token.balanceOf(buyer), token.MAX_WALLET());
    }

    /// $KYZN leaving the pool is a buy, a liquidity removal's too: removeLiquidityETH forwards the
    /// amount the pair burned, which the router no longer holds after the tax, and reverts; the
    /// fee-on-transfer variant forwards what arrived, the amount less the 5% buy tax.
    function test_removing_liquidity_needs_the_fee_on_transfer_route_and_pays_the_buy_tax() public {
        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        KyznToken token = l.token();
        address pair = l.pair();
        IRouterRemoveLiquidity remover = IRouterRemoveLiquidity(address(router));
        uint256 part = l.lpTokens() / 100; // about 1% of the pool: 9,000,000 $KYZN, under the max wallet
        vm.prank(owner);
        IERC20(pair).approve(address(router), type(uint256).max);

        vm.prank(owner);
        vm.expectRevert(bytes("TransferHelper: TRANSFER_FAILED"));
        remover.removeLiquidityETH(address(token), part, 0, 0, owner, block.timestamp);

        (uint256 kyznReserve, uint256 ethReserve) = _reserves(l);
        uint256 lpSupply = ILaunchTestPair(pair).totalSupply();
        uint256 kyznOut = part * kyznReserve / lpSupply;
        uint256 ethOut = part * ethReserve / lpSupply;
        uint256 tax = kyznOut * 500 / 10_000;
        uint256 ethBefore = owner.balance;
        vm.prank(owner);
        remover.removeLiquidityETHSupportingFeeOnTransferTokens(address(token), part, 0, 0, owner, block.timestamp);
        assertEq(token.balanceOf(owner), kyznOut - tax);
        assertEq(token.balanceOf(address(token)), tax);
        assertEq(token.reserveTaxTokens(), tax * 200 / 500);
        assertEq(token.stakingTaxTokens(), tax * 100 / 500);
        assertEq(token.balanceOf(address(router)), 0);
        assertEq(owner.balance - ethBefore, ethOut);
    }

    /// While the max wallet is on, a removal that would leave the router holding more than 2% of
    /// supply reverts in the pair; once the owner removes the limit, it goes through.
    function test_a_removal_above_2_percent_reverts_until_the_max_wallet_is_removed() public {
        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        KyznToken token = l.token();
        IRouterRemoveLiquidity remover = IRouterRemoveLiquidity(address(router));
        uint256 part = l.lpTokens() / 20; // about 5% of the pool: 45,000,000 $KYZN
        vm.startPrank(owner);
        IERC20(l.pair()).approve(address(router), type(uint256).max);
        vm.expectRevert(bytes("UniswapV2: TRANSFER_FAILED"));
        remover.removeLiquidityETHSupportingFeeOnTransferTokens(address(token), part, 0, 0, owner, block.timestamp);

        token.acceptOwnership();
        token.removeMaxWallet();
        remover.removeLiquidityETHSupportingFeeOnTransferTokens(address(token), part, 0, 0, owner, block.timestamp);
        vm.stopPrank();
        assertGt(token.balanceOf(owner), token.MAX_WALLET());
    }

    /// $KYZN entering the pool is a sell, a liquidity add's too: after the untaxed launch liquidity,
    /// adding liquidity pays the 10% sell tax, and only the rest reaches the pool.
    function test_adding_liquidity_after_the_launch_pays_the_sell_tax() public {
        KyzenLaunch l = _launch(_setup(), LIQUIDITY_ETH);
        KyznToken token = l.token();
        vm.prank(buyer);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(
            0, _path(address(weth), address(token)), buyer, block.timestamp
        );
        uint256 pending = token.balanceOf(address(token));
        uint256 added = 1_000_000e18;
        assertLt(pending + added / 10, token.swapThreshold()); // no tax sale in between
        (uint256 kyznBefore,) = _reserves(l);

        vm.startPrank(buyer);
        token.approve(address(router), added);
        router.addLiquidityETH{value: 1 ether}(address(token), added, 0, 0, buyer, block.timestamp);
        vm.stopPrank();

        uint256 tax = added * 1_000 / 10_000;
        assertEq(token.balanceOf(address(token)), pending + tax);
        (uint256 kyznAfter,) = _reserves(l);
        assertEq(kyznAfter - kyznBefore, added - tax);
        assertGt(ILaunchTestPair(l.pair()).balanceOf(buyer), 0);
    }

    // ---------------------------------------------------------------- refusals

    function test_each_empty_required_setting_stops_the_launch_by_name() public {
        string[2] memory names = ["KEEPER", "OPERATOR"];
        for (uint256 i; i < names.length; ++i) {
            KyzenLaunch.Setup memory s = _setup();
            if (i == 0) s.keeper = address(0);
            if (i == 1) s.operator = address(0);
            vm.expectRevert(abi.encodeWithSelector(KyzenLaunch.SettingNotSet.selector, names[i]));
            _launch(s, LIQUIDITY_ETH);
        }
    }

    /// An empty development, team or host-payout wallet is the deploying owner's wallet.
    function test_empty_wallets_are_the_owner_s_wallet() public {
        KyzenLaunch.Setup memory s = _setup();
        s.devWallet = address(0);
        s.teamWallet = address(0);
        s.hostPayout = address(0);
        KyzenLaunch l = _launch(s, LIQUIDITY_ETH);
        assertEq(l.token().devWallet(), owner);
        assertEq(l.gateway().hostPayout(), owner);
        assertEq(sablier.getRecipient(l.streamId()), owner);
        assertEq(sablier.getSender(l.streamId()), owner);
    }

    function test_too_little_eth_stops_the_launch() public {
        uint256 needed = LIQUIDITY_ETH;
        vm.expectRevert(abi.encodeWithSelector(KyzenLaunch.NotEnoughEth.selector, needed, needed - 1));
        _launch(_setup(), needed - 1);
    }

    function test_a_deployer_that_cannot_take_the_refund_stops_the_launch() public {
        address rejecter = address(new RejectingReceiver());
        vm.deal(rejecter, 10 ether);
        KyzenLaunch.Setup memory s = _setup();
        vm.prank(rejecter);
        vm.expectRevert(KyzenLaunch.RefundFailed.selector);
        new KyzenLaunch{value: 3 ether}(s);
    }

    /// The mainnet launch runs only on Robinhood Chain.
    function test_the_mainnet_launch_refuses_another_chain() public {
        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, block.chainid));
        this.mainnetSetupExternal();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, block.chainid));
        new KyzenMainnetLaunch{value: LIQUIDITY_ETH}(dev, team, host, keeper, operator);
    }

    function mainnetSetupExternal() external view returns (KyzenLaunch.Setup memory) {
        return mainnetSetup(dev, team, host, keeper, operator);
    }
}
