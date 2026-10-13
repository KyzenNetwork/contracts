// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {KyzenLaunch} from "../../script/KyzenLaunch.sol";
import {KyzenMainnetLaunch, mainnetSetup} from "../../script/KyzenMainnetLaunch.sol";
import {LaunchMainnet} from "../../script/LaunchMainnet.s.sol";
import {Months} from "../../script/lib/Months.sol";
import {ISablierLockup} from "../../script/interfaces/ISablierLockup.sol";
import {IUniswapV2Locker} from "../../script/interfaces/IUniswapV2Locker.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";

interface IUniswapV2FactoryCreate {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IWETHDeposit {
    function deposit() external payable;
}

interface IForkPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
}

/// The mainnet launch (script/KyzenMainnetLaunch.sol's setup, deployed as one transaction)
/// against real Robinhood Chain mainnet state: Uniswap v2's factory and Router02, WETH, Sablier
/// Lockup v4.0, the seven stock tokens and their Chainlink feeds, and Uniswap v3's SwapRouter02;
/// then the owner's lock of the LP tokens on UNCX's V2 locker, by hand, as UNCX's app sends it.
/// Only the owner's settings are test addresses.
contract KyzenLaunchForkTest is Test {
    IUniswapV2Locker internal constant LOCKER = IUniswapV2Locker(RH.UNCX_V2_LOCKER);
    ISablierLockup internal constant SABLIER = ISablierLockup(RH.SABLIER_LOCKUP);
    IUniswapV2Router02 internal constant ROUTER = IUniswapV2Router02(RH.UNISWAP_V2_ROUTER);
    /// The country code UNCX's app sends for every lock on this locker ("Other" in UNCX's list).
    uint16 internal constant UNCX_APP_COUNTRY = 0;
    uint256 internal constant VALUE = 2 ether;

    address internal owner = makeAddr("owner");
    address internal dev = makeAddr("dev");
    address internal team = makeAddr("team");
    address internal host = makeAddr("host");
    address internal keeper = makeAddr("keeper");
    address internal operator = makeAddr("operator");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork("robinhood");
        vm.deal(owner, 10 ether);
        vm.deal(buyer, 1 ether);
    }

    function _launch(uint256 value) internal returns (KyzenLaunch l) {
        KyzenLaunch.Setup memory s = mainnetSetup(dev, team, host, keeper, operator);
        uint256 before = gasleft();
        vm.prank(owner);
        l = new KyzenLaunch{value: value}(s);
        emit log_named_uint("launch gas (execution, before the chain's data fee)", before - gasleft());
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _reserves(KyzenLaunch l) internal view returns (uint256 kyzn, uint256 eth) {
        IForkPair p = IForkPair(l.pair());
        (uint112 r0, uint112 r1,) = p.getReserves();
        (kyzn, eth) = p.token0() == address(l.token()) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// The owner's lock by hand right after the launch, as UNCX's app sends it: every LP token for 6
    /// months, the fee in ETH, no referral, the owner as withdrawer, country code 0.
    function _lockByHand(address pair, uint256 lp) internal returns (uint256 locked) {
        (uint256 ethFee,,,, uint256 lpFeePerMille,,,,) = LOCKER.gFees();
        vm.startPrank(owner);
        IERC20(pair).approve(address(LOCKER), lp);
        LOCKER.lockLPToken{value: ethFee}(
            pair, lp, Months.add(block.timestamp, 6), payable(address(0)), true, payable(owner), UNCX_APP_COUNTRY
        );
        vm.stopPrank();
        locked = lp - lp * lpFeePerMille / 1000;
    }

    function test_uncx_fees_for_the_lock_by_hand() public view {
        (uint256 ethFee,,,, uint256 lpFeePerMille,,,,) = LOCKER.gFees();
        assertEq(ethFee, 0.1 ether);
        assertEq(lpFeePerMille, 10);
    }

    function test_the_mainnet_launch_runs_in_one_transaction() public {
        uint256 start = block.timestamp;
        KyzenLaunch l = _launch(VALUE);
        KyznToken token = l.token();
        address pair = l.pair();

        // Pool: 900,000,000 $KYZN and 2 ETH, trading open at the launch taxes: 5% on buys, 10% on sells.
        (uint256 kyznReserve, uint256 ethReserve) = _reserves(l);
        assertEq(kyznReserve, 900_000_000e18);
        assertEq(ethReserve, 2 ether);
        assertEq(token.launchedAt(), start);
        assertEq(token.buyTaxBps(), 500);
        assertEq(token.sellTaxBps(), 1_000);
        assertEq(owner.balance, 10 ether - VALUE);

        // Every LP token but Uniswap's 1,000 goes to the owner, who locks them on UNCX by hand: all
        // of them but UNCX's 1%, for 6 months, withdrawable by the owner alone.
        uint256 lp = IForkPair(pair).totalSupply() - 1_000;
        assertEq(l.lpTokens(), lp);
        assertEq(IERC20(pair).balanceOf(owner), lp);
        assertEq(IERC20(pair).balanceOf(address(l)), 0);
        uint256 locked = _lockByHand(pair, lp);
        assertEq(locked, lp - lp / 100);
        assertEq(LOCKER.getUserNumLocksForToken(owner, pair), 1);
        IUniswapV2Locker.TokenLock memory lock = LOCKER.getUserLockForTokenAtIndex(owner, pair, 0);
        assertEq(lock.amount, locked);
        assertEq(lock.owner, owner);
        assertEq(lock.unlockDate, Months.add(start, 6));
        assertEq(lock.countryCode, UNCX_APP_COUNTRY);
        assertEq(IERC20(pair).balanceOf(owner), 0);

        // Sablier: 100,000,000 $KYZN to the team, nothing before the cliff, all of it at the end.
        uint256 id = l.streamId();
        assertEq(SABLIER.getRecipient(id), team);
        assertEq(SABLIER.getSender(id), owner);
        assertEq(uint256(SABLIER.getDepositedAmount(id)), 100_000_000e18);
        assertEq(uint256(SABLIER.getCliffTime(id)), Months.add(start, 6));
        assertEq(uint256(SABLIER.getEndTime(id)), Months.add(start, 18));
        assertFalse(SABLIER.isCancelable(id));
        assertFalse(SABLIER.isTransferable(id));

        // The Reserve lists all seven stock tokens and can use SwapRouter02 a day later.
        assertEq(l.reserve().assetCount(), 7);
        assertEq(l.reserve().keeper(), keeper);
        assertEq(l.gateway().operator(), operator);
        assertEq(l.gateway().hostPayout(), host);
        assertEq(l.staking().equityAssetA(), RH.NVDA);
        assertEq(l.staking().equityAssetB(), RH.AMD);

        // The launch contract keeps nothing and owns nothing once the owner accepts.
        assertEq(token.balanceOf(address(l)), 0);
        assertEq(address(l).balance, 0);
        assertEq(token.pendingOwner(), owner);

        vm.warp(Months.add(start, 6) - 1);
        assertEq(uint256(SABLIER.streamedAmountOf(id)), 0);
        // Linear over the 12 months after the cliff (SPEC 3.1), not from the start: halfway through
        // them about 50,000,000 has streamed (linear from the start would be about 66,700,000).
        vm.warp(Months.add(start, 12));
        assertApproxEqRel(uint256(SABLIER.streamedAmountOf(id)), 50_000_000e18, 0.01e18);
        vm.warp(Months.add(start, 18));
        assertEq(uint256(SABLIER.streamedAmountOf(id)), 100_000_000e18);
        assertTrue(l.reserve().isTargetAllowed(RH.UNISWAP_V3_SWAP_ROUTER_02));
    }

    /// A fresh wallet buys and sells its whole balance through Router02 right after the launch,
    /// as a token scanner does, and pays exactly the launch taxes: 5% on the buy, 10% on the sell.
    function test_a_fresh_wallet_buys_and_sells_right_after_the_launch() public {
        KyzenLaunch l = _launch(VALUE);
        KyznToken token = l.token();
        (uint256 kyznReserve, uint256 ethReserve) = _reserves(l);
        uint256 withFee = 0.01 ether * 997;
        uint256 gross = withFee * kyznReserve / (ethReserve * 1000 + withFee);

        vm.prank(buyer);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(
            0, _path(RH.WETH, address(token)), buyer, block.timestamp
        );
        uint256 bought = token.balanceOf(buyer);
        assertEq(bought, gross - gross * 500 / 10_000); // the 5% buy tax

        // The buy's tax is below the swap threshold, so the sell meets no tax swap: it pays the 10%
        // sell tax and the rest reaches the pool at the reserves the buy left.
        assertLt(token.balanceOf(address(token)), token.swapThreshold());
        (kyznReserve, ethReserve) = _reserves(l);
        uint256 net = bought - bought * 1_000 / 10_000;
        uint256 expectedEth = net * 997 * ethReserve / (kyznReserve * 1000 + net * 997);
        uint256 ethBefore = buyer.balance;
        vm.startPrank(buyer);
        token.approve(address(ROUTER), bought);
        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            bought, 0, _path(address(token), RH.WETH), buyer, block.timestamp
        );
        vm.stopPrank();
        assertEq(token.balanceOf(buyer), 0);
        assertEq(buyer.balance - ethBefore, expectedEth);
    }

    function test_the_owner_accepts_ownership_lowers_the_tax_and_renounces() public {
        KyzenLaunch l = _launch(VALUE);
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
    }

    function test_eth_beyond_the_liquidity_comes_back() public {
        _launch(3 ether);
        assertEq(owner.balance, 10 ether - VALUE);
    }

    /// The mainnet launch refuses to run without KEEPER and OPERATOR, by name.
    function test_the_mainnet_launch_refuses_to_run_without_keeper_and_operator() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KyzenLaunch.SettingNotSet.selector, "KEEPER"));
        new KyzenMainnetLaunch{value: VALUE}(dev, team, host, address(0), operator);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KyzenLaunch.SettingNotSet.selector, "OPERATOR"));
        new KyzenMainnetLaunch{value: VALUE}(dev, team, host, keeper, address(0));
    }

    /// The deploy page's path: KyzenMainnetLaunch with its five constructor arguments, the optional
    /// wallets left zero (the deploying wallet).
    function test_the_mainnet_launch_with_constructor_arguments() public {
        vm.prank(owner);
        KyzenMainnetLaunch l =
            new KyzenMainnetLaunch{value: VALUE}(address(0), address(0), address(0), keeper, operator);
        assertEq(l.token().devWallet(), owner);
        assertEq(l.gateway().hostPayout(), owner);
        assertEq(l.reserve().keeper(), keeper);
        assertEq(l.gateway().operator(), operator);
        assertEq(IERC20(l.pair()).balanceOf(owner), l.lpTokens());
    }

    /// The command-line launch sends the 2 ETH and, with KEEPER still empty, stops by name.
    function test_the_command_line_launch_refuses_to_run_until_the_settings_are_filled_in() public {
        LaunchMainnet script = new LaunchMainnet();
        vm.deal(DEFAULT_SENDER, 10 ether);
        vm.expectRevert(abi.encodeWithSelector(KyzenLaunch.SettingNotSet.selector, "KEEPER"));
        script.run();
    }

    /// The launch needs the full 2 ETH of liquidity.
    function test_less_than_the_liquidity_stops_the_launch() public {
        KyzenLaunch.Setup memory s = mainnetSetup(dev, team, host, keeper, operator);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KyzenLaunch.NotEnoughEth.selector, VALUE, VALUE - 1));
        new KyzenLaunch{value: VALUE - 1}(s);
    }

    /// With the three optional wallets left empty, each is the owner's wallet, the team stream too,
    /// on the real Sablier (sender and recipient the same wallet).
    function test_empty_wallets_are_the_owner_s_wallet() public {
        KyzenLaunch.Setup memory s = mainnetSetup(address(0), address(0), address(0), keeper, operator);
        vm.prank(owner);
        KyzenLaunch l = new KyzenLaunch{value: VALUE}(s);
        assertEq(l.token().devWallet(), owner);
        assertEq(l.gateway().hostPayout(), owner);
        uint256 id = l.streamId();
        assertEq(SABLIER.getRecipient(id), owner);
        assertEq(SABLIER.getSender(id), owner);
        vm.warp(Months.add(block.timestamp, 18));
        assertEq(uint256(SABLIER.streamedAmountOf(id)), 100_000_000e18);
    }

    /// On mainnet's real Uniswap v2: a pair pre-created at the token's predicted address, with WETH
    /// donated to it, does not stop the launch; the donation joins the pool and its LP goes to the
    /// owner with the rest.
    function test_a_pre_created_pair_with_donated_weth_does_not_stop_the_launch() public {
        address predictedLaunch = vm.computeCreateAddress(owner, vm.getNonce(owner));
        address predictedToken = vm.computeCreateAddress(predictedLaunch, 2);
        address pre = IUniswapV2FactoryCreate(RH.UNISWAP_V2_FACTORY).createPair(predictedToken, RH.WETH);
        vm.deal(address(this), 1 ether);
        IWETHDeposit(RH.WETH).deposit{value: 1 ether}();
        IERC20(RH.WETH).transfer(pre, 1 ether);

        KyzenLaunch l = _launch(VALUE);
        assertEq(l.pair(), pre);
        (uint256 kyznReserve, uint256 ethReserve) = _reserves(l);
        assertEq(kyznReserve, 900_000_000e18);
        assertEq(ethReserve, 3 ether);
        assertEq(IERC20(pre).balanceOf(address(l)), 0);
        assertEq(IERC20(pre).balanceOf(owner), l.lpTokens());
    }

    function test_lp_math_matches_uniswap() public {
        KyzenLaunch l = _launch(VALUE);
        assertEq(IForkPair(l.pair()).totalSupply(), Math.sqrt(900_000_000e18 * uint256(2 ether)));
    }
}
