// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {WeightRegistry} from "../../src/WeightRegistry.sol";
import {Reserve} from "../../src/Reserve.sol";
import {Staking} from "../../src/Staking.sol";
import {GatewaySettlement} from "../../src/GatewaySettlement.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IKyzn} from "../../src/interfaces/IKyzn.sol";
import {IRotationState} from "../../src/interfaces/IRotationState.sol";
import {IReserveView} from "../../src/interfaces/IReserveView.sol";
import {KyzenLaunch} from "../../script/KyzenLaunch.sol";
import {mainnetSetup} from "../../script/KyzenMainnetLaunch.sol";
import {Months} from "../../script/lib/Months.sol";
import {ISablierLockup} from "../../script/interfaces/ISablierLockup.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";

/// The $KYZN/WETH pair, as far as the token-first launch needs it.
interface ITokenFirstPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
    function sync() external;
}

/// Two Sablier Lockup v4.0 views that script/interfaces/ISablierLockup.sol leaves out.
interface ISablierLockupStreamViews {
    function getStartTime(uint256 streamId) external view returns (uint40 startTime);
    function getUnderlyingToken(uint256 streamId) external view returns (IERC20 token);
}

/// The later step's liquidity in one call from the owner wallet: KyzenLaunch._addLiquidity, with
/// the owner's own $KYZN. Once the owner has approved it for the $KYZN, it moves the $KYZN from the
/// owner wallet straight to the pair, wraps the ETH sent with the call and sends it to the pair,
/// and mints the LP tokens to the owner wallet. It keeps nothing.
/// Why the later step needs it and not Router02 (test_4c): from the token's deployment until the
/// liquidity, the pair exists and is empty, and anyone may send it WETH and call sync(). Router02
/// then quotes the $KYZN against a pool with WETH and no $KYZN and reverts, whatever the minimums;
/// so does any add through Router02, the Uniswap app's included. This helper does not quote: the
/// donated WETH simply joins the pool. And since the transfers and the mint run in one call,
/// nothing can come between them: no one can skim the $KYZN or sync a half-filled pool.
contract AtomicLiquidity {
    using SafeERC20 for IERC20;

    function add(KyznToken token, uint256 kyznAmount) external payable returns (uint256 liquidity) {
        address pair = token.pair();
        IERC20(address(token)).safeTransferFrom(msg.sender, pair, kyznAmount);
        IWETH weth = IWETH(token.weth());
        weth.deposit{value: msg.value}();
        IERC20(address(weth)).safeTransfer(pair, msg.value);
        liquidity = ITokenFirstPair(pair).mint(msg.sender);
    }
}

/// The token-first launch against real Robinhood Chain mainnet state: Uniswap v2's factory and
/// Router02, WETH, Sablier Lockup v4.0, the seven stock tokens and their Chainlink feeds. The owner
/// deploys KyznToken alone, straight from the owner wallet (Router02, the owner wallet as the
/// development wallet, no value, nothing else): setUp. A day later, from the same wallet, it
/// deploys and wires the other four contracts as KyzenLaunch does, creates the team's Sablier
/// stream with KyzenLaunch's parameters, and adds the 900,000,000 $KYZN and 2 ETH of liquidity.
/// Each test starts from the token alone and proves one of those later steps on it.
/// Run it against a local fork of Robinhood Chain mainnet with --fork-url; without one it forks
/// `robinhood` itself, as the other fork tests do. Every wallet is a fresh address: on Robinhood
/// Chain mainnet, anvil's well-known default accounts carry an EIP-7702 delegation that sweeps
/// incoming ETH.
contract TokenFirstForkTest is Test {
    IUniswapV2Router02 internal constant ROUTER = IUniswapV2Router02(RH.UNISWAP_V2_ROUTER);
    ISablierLockup internal constant SABLIER = ISablierLockup(RH.SABLIER_LOCKUP);
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    /// KyzenLaunch's amounts and months (SPEC 3.1); the 2 ETH is also mainnetSetup's liquidityEth.
    uint128 internal constant TEAM_STREAM = 100_000_000e18;
    uint256 internal constant LIQUIDITY_KYZN = 900_000_000e18;
    uint256 internal constant LIQUIDITY_ETH = 2 ether;
    uint256 internal constant CLIFF_MONTHS = 6;
    uint256 internal constant STREAM_MONTHS = 18;
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;
    /// The later step runs a day after the token.
    uint256 internal constant LATER = 1 days;

    address internal owner = makeAddr("owner");
    address internal team = makeAddr("team");
    address internal keeper = makeAddr("keeper");
    address internal operator = makeAddr("operator");
    address internal buyer = makeAddr("buyer");
    address internal seller = makeAddr("seller");
    address internal whale = makeAddr("whale");
    address internal wallet = makeAddr("wallet");
    address internal griefer = makeAddr("griefer");

    KyznToken internal token;
    address internal pair;
    uint256 internal deployedAt;
    uint256 internal tokenDeployGas;

    WeightRegistry internal registry;
    Reserve internal reserve;
    Staking internal staking;
    GatewaySettlement internal gateway;
    uint256 internal streamId;
    uint256 internal streamStart;

    /// The tax sale a sell triggers, as the token computes it.
    struct TaxSale {
        uint256 kyznReserve;
        uint256 ethReserve;
        uint256 pending;
        uint256 recordedReserve;
        uint256 recordedStaking;
        uint256 sold;
        uint256 received;
        uint256 reserveSold;
        uint256 stakingSold;
        uint256 toReserve;
        uint256 toStaking;
        uint256 toDevelopment;
    }

    function setUp() public {
        if (block.chainid != RH.CHAIN_ID) vm.createSelectFork("robinhood");
        address[9] memory wallets = [owner, team, keeper, operator, buyer, seller, whale, wallet, griefer];
        for (uint256 i; i < wallets.length; ++i) {
            assertEq(wallets[i].code.length, 0, "a wallet has code on this chain");
        }
        // A sell through Router02's fee-on-transfer route sweeps any WETH the router holds; the
        // exact amounts below assume it holds none.
        assertEq(IERC20(RH.WETH).balanceOf(address(ROUTER)), 0, "Router02 holds WETH");
        vm.deal(owner, 10 ether);

        // The owner wallet's one deployment: the token alone.
        vm.prank(owner);
        uint256 before = gasleft();
        token = new KyznToken(ROUTER, owner);
        tokenDeployGas = before - gasleft();
        pair = token.pair();
        deployedAt = block.timestamp;
    }

    // ---------------------------------------------------------------- 1. the token alone

    function test_1_the_token_deploys_alone_from_the_owner_wallet() public {
        // The CREATE as this test sends it: a deployment transaction adds its 21,000 base and its
        // calldata, and Robinhood Chain its data fee.
        emit log_named_uint("token deployment gas (fork, execution)", tokenDeployGas);

        // The owner wallet owns it directly: nothing to accept, nothing pending.
        assertEq(token.owner(), owner);
        assertEq(token.pendingOwner(), address(0));
        assertEq(token.totalSupply(), SUPPLY);
        assertEq(token.balanceOf(owner), SUPPLY);

        // Its pair is the real factory's, for $KYZN and WETH, and empty.
        assertEq(pair, IUniswapV2Factory(RH.UNISWAP_V2_FACTORY).getPair(address(token), RH.WETH));
        assertTrue(pair != address(0));
        ITokenFirstPair p = ITokenFirstPair(pair);
        assertTrue(
            (p.token0() == address(token) && p.token1() == RH.WETH)
                || (p.token0() == RH.WETH && p.token1() == address(token))
        );
        (uint112 r0, uint112 r1,) = p.getReserves();
        assertEq(r0, 0);
        assertEq(r1, 0);
        assertEq(p.totalSupply(), 0);
        assertEq(address(token.router()), RH.UNISWAP_V2_ROUTER);
        assertEq(token.weth(), RH.WETH);

        // The launch settings: 5% on buys, 10% on sells, the max wallet on, the owner wallet as the
        // development wallet, no protocol addresses yet, launchedAt the deployment's time.
        assertEq(token.buyTaxBps(), 500);
        assertEq(token.sellTaxBps(), 1_000);
        assertTrue(token.maxWalletActive());
        assertEq(token.devWallet(), owner);
        assertEq(token.reserve(), address(0));
        assertEq(token.staking(), address(0));
        assertEq(token.gateway(), address(0));
        assertEq(token.launchedAt(), block.timestamp);

        // Before the liquidity nobody can buy: Router02 finds no reserves.
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(bytes("UniswapV2Library: INSUFFICIENT_LIQUIDITY"));
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(
            0, _path(RH.WETH, address(token)), buyer, block.timestamp
        );

        // A transfer from the owner wallet to another wallet is untaxed, and not limited either: the
        // max wallet applies to buys only.
        vm.prank(owner);
        assertTrue(token.transfer(wallet, 25_000_000e18));
        assertEq(token.balanceOf(wallet), 25_000_000e18);
        assertEq(token.balanceOf(owner), SUPPLY - 25_000_000e18);
        _assertNoTax();
    }

    // ---------------------------------------------------------------- 2. the four contracts

    function test_2_the_four_contracts_deploy_and_wire_from_the_owner_wallet() public {
        vm.warp(block.timestamp + LATER);
        _stage();

        // The owner wallet owns each directly, as it owns the token.
        assertEq(registry.owner(), owner);
        assertEq(reserve.owner(), owner);
        assertEq(staking.owner(), owner);
        assertEq(gateway.owner(), owner);
        assertEq(registry.pendingOwner(), address(0));
        assertEq(reserve.pendingOwner(), address(0));
        assertEq(staking.pendingOwner(), address(0));
        assertEq(gateway.pendingOwner(), address(0));

        // The Reserve: this token, WETH, the ETH/USD feed, the registry, the seven stock tokens, the
        // keeper, and SwapRouter02 queued.
        assertEq(address(reserve.kyzn()), address(token));
        assertEq(address(reserve.weth()), RH.WETH);
        assertEq(reserve.ethUsdFeed(), RH.ETH_USD_FEED);
        assertEq(address(reserve.registry()), address(registry));
        RH.Asset[7] memory list = RH.assets();
        assertEq(reserve.assetCount(), list.length);
        for (uint256 i; i < list.length; ++i) {
            assertEq(reserve.assets(i), list[i].token);
            (address feed,, uint8 stage,, bool listed) = reserve.assetInfo(list[i].token);
            assertEq(feed, list[i].feed);
            assertEq(stage, list[i].stage);
            assertTrue(listed);
        }
        assertEq(reserve.keeper(), keeper);
        assertFalse(reserve.isTargetAllowed(RH.UNISWAP_V3_SWAP_ROUTER_02));

        // Staking and the Gateway.
        assertEq(address(staking.kyzn()), address(token));
        assertEq(address(staking.router()), RH.UNISWAP_V2_ROUTER);
        assertEq(address(staking.weth()), RH.WETH);
        assertEq(address(staking.reserve()), address(reserve));
        assertEq(staking.equityAssetA(), RH.NVDA);
        assertEq(staking.equityAssetB(), RH.AMD);
        assertEq(address(gateway.kyzn()), address(token));
        assertEq(address(gateway.router()), RH.UNISWAP_V2_ROUTER);
        assertEq(gateway.hostPayout(), owner);
        assertEq(gateway.operator(), operator);

        // The token took the three protocol addresses and exempts them; the owner wallet stays the
        // development wallet, and taxed; launchedAt stays the token's deployment time.
        assertEq(token.reserve(), address(reserve));
        assertEq(token.staking(), address(staking));
        assertEq(token.gateway(), address(gateway));
        assertTrue(token.isExempt(address(reserve)));
        assertTrue(token.isExempt(address(staking)));
        assertTrue(token.isExempt(address(gateway)));
        assertFalse(token.isExempt(owner));
        assertEq(token.devWallet(), owner);
        assertEq(token.launchedAt(), deployedAt);

        // SwapRouter02 is the Reserve's swap target 24 hours after it was queued.
        vm.warp(block.timestamp + 24 hours);
        assertTrue(reserve.isTargetAllowed(RH.UNISWAP_V3_SWAP_ROUTER_02));
    }

    // ---------------------------------------------------------------- 3. the team stream

    function test_3_the_team_stream_from_the_owner_wallet_is_untaxed() public {
        vm.warp(block.timestamp + LATER);
        _stage();
        uint256 ownerBefore = token.balanceOf(owner);
        _stream();
        uint256 id = streamId;
        uint256 start = streamStart;
        assertEq(start, deployedAt + LATER);

        ISablierLockupStreamViews views = ISablierLockupStreamViews(address(SABLIER));
        assertEq(SABLIER.getRecipient(id), team);
        assertEq(SABLIER.getSender(id), owner);
        assertEq(address(views.getUnderlyingToken(id)), address(token));
        assertEq(uint256(SABLIER.getDepositedAmount(id)), 100_000_000e18);
        assertEq(uint256(views.getStartTime(id)), start);
        assertEq(uint256(SABLIER.getCliffTime(id)), Months.add(start, 6));
        assertEq(uint256(SABLIER.getEndTime(id)), Months.add(start, 18));
        assertFalse(SABLIER.isCancelable(id));
        assertFalse(SABLIER.isTransferable(id));

        // No tax: the owner wallet paid exactly the deposit and Sablier holds all of it.
        assertEq(ownerBefore - token.balanceOf(owner), 100_000_000e18);
        assertEq(token.balanceOf(address(SABLIER)), 100_000_000e18);
        assertEq(token.allowance(owner, address(SABLIER)), 0);
        _assertNoTax();

        // Nothing before the cliff, linear over the 12 months after it, all of it at the end.
        vm.warp(Months.add(start, 6) - 1);
        assertEq(uint256(SABLIER.streamedAmountOf(id)), 0);
        vm.warp(Months.add(start, 12));
        assertApproxEqRel(uint256(SABLIER.streamedAmountOf(id)), 50_000_000e18, 0.01e18);
        vm.warp(Months.add(start, 18));
        assertEq(uint256(SABLIER.streamedAmountOf(id)), 100_000_000e18);
    }

    // ---------------------------------------------------------------- 4. the liquidity

    /// (a) The atomic helper, in one call from the owner wallet: the first liquidity goes in untaxed.
    function test_4a_the_atomic_helper_adds_the_liquidity_untaxed() public {
        _preLiquidity();
        uint256 ethBefore = owner.balance;
        (AtomicLiquidity helper, uint256 lp) = _addLiquidityAtomically();

        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, LIQUIDITY_KYZN);
        assertEq(ethReserve, LIQUIDITY_ETH);
        assertEq(token.balanceOf(pair), LIQUIDITY_KYZN);
        // Every LP token but Uniswap's 1,000 to the owner wallet.
        assertEq(lp, Math.sqrt(LIQUIDITY_KYZN * LIQUIDITY_ETH) - MINIMUM_LIQUIDITY);
        assertEq(ITokenFirstPair(pair).balanceOf(owner), lp);
        assertEq(ITokenFirstPair(pair).totalSupply(), lp + MINIMUM_LIQUIDITY);
        // The owner wallet paid the 2 ETH and kept no $KYZN: 100,000,000 in the stream, the rest in
        // the pool.
        assertEq(owner.balance, ethBefore - LIQUIDITY_ETH);
        assertEq(token.balanceOf(owner), 0);
        _assertNoTax();

        // The helper keeps nothing and has no allowance left.
        assertEq(token.balanceOf(address(helper)), 0);
        assertEq(IERC20(RH.WETH).balanceOf(address(helper)), 0);
        assertEq(ITokenFirstPair(pair).balanceOf(address(helper)), 0);
        assertEq(address(helper).balance, 0);
        assertEq(token.allowance(owner, address(helper)), 0);
    }

    /// (b) On the clean pair, Router02's addLiquidityETH from the owner wallet works too, untaxed.
    function test_4b_router02_adds_the_liquidity_untaxed_on_a_clean_pair() public {
        _preLiquidity();
        vm.startPrank(owner);
        token.approve(address(ROUTER), LIQUIDITY_KYZN);
        (uint256 amountToken, uint256 amountEth, uint256 lp) = ROUTER.addLiquidityETH{value: LIQUIDITY_ETH}(
            address(token), LIQUIDITY_KYZN, LIQUIDITY_KYZN, LIQUIDITY_ETH, owner, block.timestamp
        );
        vm.stopPrank();

        assertEq(amountToken, LIQUIDITY_KYZN);
        assertEq(amountEth, LIQUIDITY_ETH);
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, LIQUIDITY_KYZN);
        assertEq(ethReserve, LIQUIDITY_ETH);
        assertEq(lp, Math.sqrt(LIQUIDITY_KYZN * LIQUIDITY_ETH) - MINIMUM_LIQUIDITY);
        assertEq(ITokenFirstPair(pair).balanceOf(owner), lp);
        assertEq(token.balanceOf(owner), 0);
        _assertNoTax();
    }

    /// (c) Anyone can send the empty pair 1 wei of WETH and sync it before the liquidity. Router02's
    /// addLiquidityETH then reverts, whatever the minimums; the atomic helper still adds the
    /// liquidity, untaxed. This is why the later step must use the helper (see AtomicLiquidity).
    function test_4c_a_synced_weth_donation_stops_router02_but_not_the_atomic_helper() public {
        _preLiquidity();
        vm.deal(griefer, 1 ether);
        vm.startPrank(griefer);
        IWETH(RH.WETH).deposit{value: 1}();
        assertTrue(IWETH(RH.WETH).transfer(pair, 1));
        ITokenFirstPair(pair).sync();
        vm.stopPrank();
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, 0);
        assertEq(ethReserve, 1);

        // Router02 quotes the $KYZN against reserves of 0 $KYZN and 1 wei, and stops.
        vm.startPrank(owner);
        token.approve(address(ROUTER), LIQUIDITY_KYZN);
        vm.expectRevert(bytes("UniswapV2Library: INSUFFICIENT_LIQUIDITY"));
        ROUTER.addLiquidityETH{value: LIQUIDITY_ETH}(address(token), LIQUIDITY_KYZN, 0, 0, owner, block.timestamp);
        vm.stopPrank();

        // The helper does not quote: the 900,000,000 $KYZN and 2 ETH go in, untaxed (the pool still
        // holds no $KYZN), the owner wallet gets the same LP as on a clean pair, and the donated wei
        // stays in the pool.
        (, uint256 lp) = _addLiquidityAtomically();
        (kyznReserve, ethReserve) = _reserves();
        assertEq(kyznReserve, LIQUIDITY_KYZN);
        assertEq(ethReserve, LIQUIDITY_ETH + 1);
        assertEq(lp, Math.sqrt(LIQUIDITY_KYZN * LIQUIDITY_ETH) - MINIMUM_LIQUIDITY);
        assertEq(ITokenFirstPair(pair).balanceOf(owner), lp);
        assertEq(token.balanceOf(owner), 0);
        _assertNoTax();
    }

    /// (d) Why no $KYZN may leave the owner wallet before the liquidity, besides the stream (which
    /// unlocks nothing for 6 months): the first liquidity is untaxed only while the pool holds no
    /// $KYZN. Any holder can mint a pool of its own first, at its own price, and the owner's
    /// 900,000,000 $KYZN then goes in as a sell and pays the 10% sell tax.
    function test_4d_kyzn_given_out_before_the_liquidity_lets_anyone_tax_the_owners_liquidity() public {
        _preLiquidity();
        vm.prank(owner);
        assertTrue(token.transfer(wallet, 1_000e18));
        vm.deal(wallet, 1 ether);
        vm.startPrank(wallet);
        assertTrue(token.transfer(pair, 1_000e18));
        IWETH(RH.WETH).deposit{value: 1 gwei}();
        assertTrue(IWETH(RH.WETH).transfer(pair, 1 gwei));
        ITokenFirstPair(pair).mint(wallet);
        vm.stopPrank();

        // The owner wallet adds all the $KYZN it has left: now a sell, 10% of it taxed.
        uint256 added = token.balanceOf(owner);
        _addLiquidityAtomically(added);
        uint256 tax = added * 1_000 / 10_000;
        assertEq(token.balanceOf(address(token)), tax);
        assertEq(token.reserveTaxTokens(), tax * 200 / 1_000);
        assertEq(token.stakingTaxTokens(), tax * 100 / 1_000);
        (uint256 kyznReserve,) = _reserves();
        assertEq(kyznReserve, 1_000e18 + added - tax);
    }

    // ---------------------------------------------------------------- 5. trading after the liquidity

    function test_5_after_the_liquidity_the_taxes_the_tax_sale_and_the_max_wallet_work() public {
        _preLiquidity();
        _addLiquidityAtomically();
        _roundTripPaysTheLaunchTaxes();
        uint256 toDevelopment = _secondRoundTripSellsTheTax();
        _anyoneSendsTheHeldEthToTheOwnerWallet(toDevelopment);
        _aBuyAboveTheMaxWalletReverts();
    }

    /// A fresh buyer buys, then sells everything: 5% on the buy and 10% on the sell, each recorded
    /// for the Reserve and Staking at the token's split, 2 and 1 points of the trade.
    function _roundTripPaysTheLaunchTaxes() internal {
        uint256 gross = _amountOut(0.01 ether, RH.WETH);
        _buy(buyer, 0.01 ether);
        uint256 buyTax = gross * 500 / 10_000;
        uint256 bought = token.balanceOf(buyer);
        assertEq(bought, gross - buyTax, "the buy pays 5%");
        assertEq(token.balanceOf(address(token)), buyTax);
        assertEq(token.reserveTaxTokens(), buyTax * 200 / 500);
        assertEq(token.stakingTaxTokens(), buyTax * 100 / 500);

        // The tax held is under the swap threshold, so this sell meets no tax sale.
        assertLt(token.balanceOf(address(token)), token.swapThreshold());
        uint256 sellTax = bought * 1_000 / 10_000;
        uint256 expectedEth = _amountOut(bought - sellTax, address(token));
        uint256 ethBefore = buyer.balance;
        _sell(buyer, bought);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(buyer.balance - ethBefore, expectedEth, "the sell pays 10%");
        assertEq(token.balanceOf(address(token)), buyTax + sellTax);
        assertEq(token.reserveTaxTokens(), buyTax * 200 / 500 + sellTax * 200 / 1_000);
        assertEq(token.stakingTaxTokens(), buyTax * 100 / 500 + sellTax * 100 / 1_000);
        assertEq(address(reserve).balance, 0);
        assertEq(address(staking).balance, 0);
        assertEq(token.totalHeldEth(), 0);
    }

    /// A second round trip: the tax held is now above the threshold, so the sell first sells it
    /// through Router02 and pays the Reserve and Staking their ETH at once; development's ETH stays
    /// held in the token for the owner wallet. Returns development's ETH.
    function _secondRoundTripSellsTheTax() internal returns (uint256) {
        _buy(seller, 0.01 ether);
        uint256 amount = token.balanceOf(seller);
        TaxSale memory t = _expectedSale(amount);
        assertGe(t.pending, token.swapThreshold());
        assertEq(t.sold, t.pending, "the whole tax held fits one sale");

        uint256 sellerEth = seller.balance;
        vm.recordLogs();
        _sell(seller, amount);
        _assertSaleLogs(t);

        assertGt(t.toReserve, 0);
        assertGt(t.toStaking, 0);
        assertGt(t.toDevelopment, 0);
        assertEq(address(reserve).balance, t.toReserve);
        assertEq(address(staking).balance, t.toStaking);
        assertEq(token.heldEth(owner), t.toDevelopment);
        assertEq(token.totalHeldEth(), t.toDevelopment);
        assertEq(address(token).balance, t.toDevelopment);

        // The sell's own 10% is taken and recorded after the sale, and the seller's $KYZN reaches
        // the pool at the reserves the sale left.
        uint256 sellTax = amount * 1_000 / 10_000;
        assertEq(token.balanceOf(address(token)), t.pending - t.sold + sellTax);
        assertEq(token.reserveTaxTokens(), t.recordedReserve - t.reserveSold + sellTax * 200 / 1_000);
        assertEq(token.stakingTaxTokens(), t.recordedStaking - t.stakingSold + sellTax * 100 / 1_000);
        assertEq(
            seller.balance - sellerEth,
            _getAmountOut(amount - sellTax, t.kyznReserve + t.sold, t.ethReserve - t.received)
        );
        return t.toDevelopment;
    }

    /// Anyone may send the held ETH; the server's operator wallet does, to the development wallet,
    /// here the owner wallet.
    function _anyoneSendsTheHeldEthToTheOwnerWallet(uint256 held) internal {
        uint256 before = owner.balance;
        vm.prank(operator);
        token.sendHeldEth(owner);
        assertEq(owner.balance - before, held);
        assertEq(token.heldEth(owner), 0);
        assertEq(token.totalHeldEth(), 0);
        assertEq(address(token).balance, 0);
    }

    /// While the max wallet is on, a buy that would take a wallet above 20,000,000 $KYZN reverts: the
    /// token's MaxWalletExceeded inside the pair's transfer, which Uniswap reports as its own
    /// TRANSFER_FAILED. The limit is what stops it: once the owner wallet removes the limit (as the
    /// direct owner, nothing to accept), the same buy goes through.
    function _aBuyAboveTheMaxWalletReverts() internal {
        assertTrue(token.maxWalletActive());
        _buy(whale, 0.04 ether);
        uint256 held = token.balanceOf(whale);
        assertLe(held, token.MAX_WALLET());
        uint256 gross = _amountOut(0.02 ether, RH.WETH);
        uint256 net = gross - gross * 500 / 10_000;
        assertGt(held + net, token.MAX_WALLET());

        vm.deal(whale, 0.02 ether);
        vm.prank(whale);
        vm.expectRevert(bytes("UniswapV2: TRANSFER_FAILED"));
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.02 ether}(
            0, _path(RH.WETH, address(token)), whale, block.timestamp
        );
        assertEq(token.balanceOf(whale), held);

        vm.prank(owner);
        token.removeMaxWallet();
        vm.prank(whale);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.02 ether}(
            0, _path(RH.WETH, address(token)), whale, block.timestamp
        );
        assertEq(token.balanceOf(whale), held + net);
        assertGt(token.balanceOf(whale), token.MAX_WALLET());
    }

    // ---------------------------------------------------------------- the later step, from the owner wallet

    /// Everything before the liquidity, a day after the token: the four contracts, then the stream.
    function _preLiquidity() internal {
        vm.warp(block.timestamp + LATER);
        _stage();
        _stream();
    }

    /// The four contracts, deployed from the owner wallet with KyzenLaunch's constructor arguments
    /// (mainnetSetup's, the host payout the owner wallet), then KyzenLaunch._wire's four calls.
    function _stage() internal {
        KyzenLaunch.Setup memory s = mainnetSetup(owner, team, owner, keeper, operator);
        assertEq(address(s.router), address(token.router()));
        assertEq(s.liquidityEth, LIQUIDITY_ETH);
        vm.startPrank(owner);
        registry = new WeightRegistry();
        reserve = new Reserve(
            IKyzn(address(token)), IWETH(token.weth()), s.ethUsdFeed, IRotationState(address(registry)), _assets(s)
        );
        staking = new Staking(
            IERC20(address(token)), s.router, IReserveView(address(reserve)), s.equityAssetA, s.equityAssetB
        );
        gateway = new GatewaySettlement(IKyzn(address(token)), s.router, s.hostPayout);
        reserve.setKeeper(s.keeper);
        reserve.queueTarget(s.swapTarget, true);
        gateway.setOperator(s.operator);
        token.setProtocolAddresses(address(reserve), address(staking), address(gateway));
        vm.stopPrank();
    }

    /// KyzenLaunch._stream's stream, from the owner wallet, which approves Sablier and is both the
    /// stream's sender and its funder: 100,000,000 $KYZN to the team wallet, a 6-month cliff with
    /// nothing unlocked at the start or the cliff, then linear to 18 months, one-second granularity,
    /// not cancelable, not transferable, shape "cliff".
    function _stream() internal {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 start = uint40(block.timestamp);
        streamStart = start;
        vm.startPrank(owner);
        token.approve(address(SABLIER), TEAM_STREAM);
        streamId = SABLIER.createWithTimestampsLL(
            ISablierLockup.CreateWithTimestamps({
                sender: owner,
                recipient: team,
                depositAmount: TEAM_STREAM,
                token: IERC20(address(token)),
                cancelable: false,
                transferable: false,
                // forge-lint: disable-next-line(unsafe-typecast)
                timestamps: ISablierLockup.Timestamps({start: start, end: uint40(Months.add(start, STREAM_MONTHS))}),
                shape: "cliff"
            }),
            ISablierLockup.UnlockAmounts({start: 0, cliff: 0}),
            0,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40(Months.add(start, CLIFF_MONTHS))
        );
        vm.stopPrank();
    }

    /// The owner wallet approves the helper for the 900,000,000 $KYZN, then calls it once with 2 ETH.
    function _addLiquidityAtomically() internal returns (AtomicLiquidity helper, uint256 lp) {
        return _addLiquidityAtomically(LIQUIDITY_KYZN);
    }

    function _addLiquidityAtomically(uint256 kyznAmount) internal returns (AtomicLiquidity helper, uint256 lp) {
        vm.startPrank(owner);
        helper = new AtomicLiquidity();
        token.approve(address(helper), kyznAmount);
        lp = helper.add{value: LIQUIDITY_ETH}(token, kyznAmount);
        vm.stopPrank();
    }

    /// KyzenLaunch._assets: the Reserve's assets, listed by its constructor.
    function _assets(KyzenLaunch.Setup memory s) internal pure returns (Reserve.AssetConfig[] memory list) {
        list = new Reserve.AssetConfig[](s.assets.length);
        for (uint256 i; i < s.assets.length; ++i) {
            list[i] = Reserve.AssetConfig({token: s.assets[i].token, feed: s.assets[i].feed, stage: s.assets[i].stage});
        }
    }

    // ---------------------------------------------------------------- helpers

    /// No tax taken and none recorded.
    function _assertNoTax() internal view {
        assertEq(token.balanceOf(address(token)), 0, "tax taken");
        assertEq(token.reserveTaxTokens(), 0);
        assertEq(token.stakingTaxTokens(), 0);
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _reserves() internal view returns (uint256 kyzn, uint256 eth) {
        ITokenFirstPair p = ITokenFirstPair(pair);
        (uint112 r0, uint112 r1,) = p.getReserves();
        (kyzn, eth) = p.token0() == address(token) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// Uniswap v2's output, 0.3% fee.
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 withFee = amountIn * 997;
        return withFee * reserveOut / (reserveIn * 1000 + withFee);
    }

    /// The output for `amountIn` of `tokenIn` at the pool's current reserves.
    function _amountOut(uint256 amountIn, address tokenIn) internal view returns (uint256) {
        (uint256 kyzn, uint256 eth) = _reserves();
        return tokenIn == address(token) ? _getAmountOut(amountIn, kyzn, eth) : _getAmountOut(amountIn, eth, kyzn);
    }

    function _buy(address who, uint256 ethIn) internal {
        vm.deal(who, who.balance + ethIn);
        vm.prank(who);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            0, _path(RH.WETH, address(token)), who, block.timestamp
        );
    }

    function _sell(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(ROUTER), amount);
        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, _path(address(token), RH.WETH), who, block.timestamp
        );
        vm.stopPrank();
    }

    /// The tax sale a sell of `sellAmount` triggers now, as KyznToken._sellTaxIfDue and _distribute
    /// compute it: at most the tax held, the sell and 0.25% of the pool's $KYZN, sold at the current
    /// reserves, its ETH split by the recorded Reserve and Staking shares of what is sold.
    function _expectedSale(uint256 sellAmount) internal view returns (TaxSale memory t) {
        (t.kyznReserve, t.ethReserve) = _reserves();
        t.pending = token.balanceOf(address(token));
        t.recordedReserve = token.reserveTaxTokens();
        t.recordedStaking = token.stakingTaxTokens();
        t.sold = Math.min(Math.min(t.pending, sellAmount), token.balanceOf(pair) * token.SWAP_POOL_BPS() / token.BPS());
        t.received = _getAmountOut(t.sold, t.kyznReserve, t.ethReserve);
        t.reserveSold = t.recordedReserve * t.sold / t.pending;
        t.stakingSold = t.recordedStaking * t.sold / t.pending;
        t.toReserve = t.received * t.reserveSold / t.sold;
        t.toStaking = t.received * t.stakingSold / t.sold;
        t.toDevelopment = t.received - t.toReserve - t.toStaking;
    }

    /// The token's TaxSwapped and TaxDistributed events match the expected sale.
    function _assertSaleLogs(TaxSale memory t) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bool swapped;
        bool distributed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(token)) continue;
            if (logs[i].topics[0] == KyznToken.TaxSwapped.selector) {
                (uint256 sold, uint256 received) = abi.decode(logs[i].data, (uint256, uint256));
                assertEq(sold, t.sold);
                assertEq(received, t.received);
                swapped = true;
            } else if (logs[i].topics[0] == KyznToken.TaxDistributed.selector) {
                (uint256 toReserve, uint256 toStaking, uint256 toDevelopment) =
                    abi.decode(logs[i].data, (uint256, uint256, uint256));
                assertEq(toReserve, t.toReserve);
                assertEq(toStaking, t.toStaking);
                assertEq(toDevelopment, t.toDevelopment);
                distributed = true;
            }
        }
        assertTrue(swapped, "no tax sale");
        assertTrue(distributed, "no distribution");
    }
}
