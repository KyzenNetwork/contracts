// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {KyzenProtocol, KyzenMainnetProtocol} from "../script/KyzenProtocol.sol";
import {KyzenLiquidity, KyzenMainnetLiquidity, NotRobinhoodToken, WrongChain} from "../script/KyzenLiquidity.sol";
import {ISablierLockup} from "../script/interfaces/ISablierLockup.sol";
import {Months} from "../script/lib/Months.sol";
import {RobinhoodChain} from "../script/RobinhoodChain.sol";
import {TestnetSablierLockup} from "../script/testnet/TestnetSablierLockup.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

/// The $KYZN/WETH pair, as these tests read and use it.
interface ILiquidityTestPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to) external returns (uint256);
    function sync() external;
}

/// Step three of the mainnet launch (script/KyzenLiquidity.sol) offline, after steps one and two as
/// on Robinhood Chain: the owner deploys the $KYZN token alone from its wallet (the development
/// wallet is that same wallet), then KyzenProtocol, sets its three contracts in the token and
/// accepts the four. Then the owner deploys KyzenLiquidity, approves it for the whole supply and
/// calls `launch` with exactly 2 ETH. It runs on the official Uniswap v2 factory and Router02 (the
/// unmodified build in external/uniswap-v2), with a stand-in WETH and the testnet stand-in for
/// Sablier Lockup (script/testnet), which keeps Sablier's rules for this stream's shape. test/fork
/// runs the steps against Robinhood Chain's own contracts.
contract KyzenLiquidityTest is Test {
    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant LIQUIDITY_KYZN = 900_000_000e18;
    uint128 internal constant TEAM_STREAM = 100_000_000e18;
    uint256 internal constant LIQUIDITY_ETH = 2 ether;
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;
    /// Thursday 1 October 2026, 12:00 UTC: steps one and two, and the liquidity contract's deployment.
    uint256 internal constant DEPLOYED_AT = 1_790_856_000;
    /// Friday 2 October 2026, 12:00 UTC: the launch, a day later.
    uint40 internal constant LAUNCH_AT = 1_790_942_400;
    /// Friday 2 April 2027, 12:00 UTC: 6 calendar months after the launch.
    uint40 internal constant CLIFF_AT = 1_806_667_200;
    /// Sunday 2 April 2028, 12:00 UTC: 18 calendar months after the launch.
    uint40 internal constant END_AT = 1_838_289_600;
    /// The server's wallets for step two (SPEC 3.1).
    address internal constant MAINNET_KEEPER = 0x9773407713fe52BfF54C5E3f519A5EA4F7334538;
    address internal constant MAINNET_OPERATOR = 0x2Ba4C980AaCcd4896d8418960D26400259C839Bb;

    MockWETH internal weth;
    address internal factory;
    IUniswapV2Router02 internal router;
    TestnetSablierLockup internal sablier;
    address internal ethUsd;
    RobinhoodChain.Asset[] internal assetList;
    KyznToken internal token;
    address internal pair;

    address internal owner = makeAddr("owner");
    address internal team = makeAddr("team");
    address internal keeper = makeAddr("keeper");
    address internal operator = makeAddr("operator");
    address internal buyer = makeAddr("buyer");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(DEPLOYED_AT);
        weth = new MockWETH();
        factory = deployCode("external/uniswap-v2/UniswapV2Factory.json", abi.encode(address(this)));
        router = IUniswapV2Router02(
            deployCode("external/uniswap-v2/UniswapV2Router02.json", abi.encode(factory, address(weth)))
        );
        sablier = new TestnetSablierLockup();
        ethUsd = address(new MockFeed(8, 2_500e8));
        RobinhoodChain.Asset[7] memory mainnet = RobinhoodChain.assets();
        for (uint256 i; i < mainnet.length; ++i) {
            assetList.push(
                RobinhoodChain.Asset({
                    token: address(new MockStockToken("STOCK")),
                    feed: address(new MockFeed(8, 100e8)),
                    stage: mainnet[i].stage
                })
            );
        }
        vm.deal(owner, 10 ether);
        // Step one, as on mainnet: the owner deploys the token alone, its own development wallet.
        vm.prank(owner);
        token = new KyznToken(router, owner);
        pair = token.pair();
    }

    // ---------------------------------------------------------------- helpers

    /// Step two, deployed by the owner and not yet set in the token.
    function _deployProtocol() internal returns (KyzenProtocol p) {
        KyzenProtocol.Setup memory s;
        s.token = token;
        s.ethUsdFeed = ethUsd;
        s.assets = assetList;
        s.equityAssetA = assetList[0].token;
        s.equityAssetB = assetList[1].token;
        s.swapTarget = address(0x5a9);
        s.keeper = keeper;
        s.operator = operator;
        vm.prank(owner);
        p = new KyzenProtocol(s);
    }

    /// The rest of step two: the three set in the token and the four accepted.
    function _setProtocol(KyzenProtocol p) internal {
        vm.startPrank(owner);
        token.setProtocolAddresses(address(p.reserve()), address(p.staking()), address(p.gateway()));
        p.registry().acceptOwnership();
        p.reserve().acceptOwnership();
        p.staking().acceptOwnership();
        p.gateway().acceptOwnership();
        vm.stopPrank();
    }

    function _protocol() internal returns (KyzenProtocol p) {
        p = _deployProtocol();
        _setProtocol(p);
    }

    function _liquiditySetup(address teamWallet) internal view returns (KyzenLiquidity.Setup memory) {
        return
            KyzenLiquidity.Setup({token: token, sablier: sablier, liquidityEth: LIQUIDITY_ETH, teamWallet: teamWallet});
    }

    function _liquidity(address teamWallet) internal returns (KyzenLiquidity l) {
        KyzenLiquidity.Setup memory s = _liquiditySetup(teamWallet);
        vm.prank(owner);
        l = new KyzenLiquidity(s);
    }

    /// Step three's two calls from the owner: the approval for the whole supply, then `launch`.
    function _approveAndLaunch(KyzenLiquidity l) internal {
        vm.startPrank(owner);
        token.approve(address(l), SUPPLY);
        l.launch{value: LIQUIDITY_ETH}();
        vm.stopPrank();
    }

    /// Steps two and three: everything deployed on DEPLOYED_AT, the launch a day later.
    function _launched() internal returns (KyzenProtocol p, KyzenLiquidity l) {
        p = _protocol();
        l = _liquidity(team);
        vm.warp(LAUNCH_AT);
        _approveAndLaunch(l);
    }

    /// The first LP minted for these amounts: Uniswap v2 keeps MINIMUM_LIQUIDITY of it for good.
    function _lp(uint256 kyzn, uint256 eth) internal pure returns (uint256) {
        return Math.sqrt(kyzn * eth) - MINIMUM_LIQUIDITY;
    }

    function _reservesOf(KyznToken t) internal view returns (uint256 kyzn, uint256 eth) {
        ILiquidityTestPair p = ILiquidityTestPair(t.pair());
        (uint112 r0, uint112 r1,) = p.getReserves();
        (kyzn, eth) = p.token0() == address(t) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    function _reserves() internal view returns (uint256 kyzn, uint256 eth) {
        return _reservesOf(token);
    }

    /// Uniswap v2's output for `amountIn` at these reserves, after its 0.3% fee.
    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 withFee = amountIn * 997;
        return withFee * reserveOut / (reserveIn * 1000 + withFee);
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
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: eth}(
            0, _path(address(weth), address(token)), who, block.timestamp
        );
        got = token.balanceOf(who) - before;
    }

    function _sell(address who, uint256 amount) internal returns (uint256 eth) {
        vm.startPrank(who);
        token.approve(address(router), amount);
        uint256 before = who.balance;
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, _path(address(token), address(weth)), who, block.timestamp
        );
        vm.stopPrank();
        eth = who.balance - before;
    }

    // ---------------------------------------------------------------- the launch

    function test_the_launch_streams_the_team_share_and_adds_the_liquidity() public {
        (KyzenProtocol p, KyzenLiquidity l) = _launched();

        // The pool: 900,000,000 $KYZN and 2 WETH; every LP token but Uniswap's locked 1,000 is the
        // owner's, at Uniswap's formula for a first deposit.
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, LIQUIDITY_KYZN);
        assertEq(ethReserve, LIQUIDITY_ETH);
        assertEq(token.balanceOf(pair), LIQUIDITY_KYZN);
        assertEq(weth.balanceOf(pair), LIQUIDITY_ETH);
        uint256 lp = _lp(LIQUIDITY_KYZN, LIQUIDITY_ETH);
        assertEq(l.lpTokens(), lp);
        assertEq(ILiquidityTestPair(pair).balanceOf(owner), lp);
        assertEq(ILiquidityTestPair(pair).totalSupply(), lp + MINIMUM_LIQUIDITY);
        assertEq(ILiquidityTestPair(pair).balanceOf(address(0)), MINIMUM_LIQUIDITY);

        // The team stream: 100,000,000 $KYZN from the owner to the team wallet, a 6-month cliff and
        // the end at 18 months, both in calendar months from the launch; it can be neither cancelled
        // nor moved.
        uint256 id = l.streamId();
        assertEq(id, 1);
        assertEq(token.balanceOf(address(sablier)), TEAM_STREAM);
        assertEq(sablier.getRecipient(id), team);
        assertEq(sablier.getSender(id), owner);
        assertEq(uint256(sablier.getDepositedAmount(id)), TEAM_STREAM);
        assertEq(uint256(sablier.getCliffTime(id)), Months.add(LAUNCH_AT, 6));
        assertEq(uint256(sablier.getEndTime(id)), Months.add(LAUNCH_AT, 18));
        assertEq(uint256(sablier.getCliffTime(id)), CLIFF_AT);
        assertEq(uint256(sablier.getEndTime(id)), END_AT);
        assertFalse(sablier.isCancelable(id));
        assertFalse(sablier.isTransferable(id));

        // The first liquidity goes in untaxed: no tax taken, none recorded.
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(uint256(token.reserveTaxTokens()), 0);
        assertEq(uint256(token.stakingTaxTokens()), 0);

        // The owner spent the whole supply and exactly 2 ETH; the contract keeps nothing.
        assertTrue(l.launched());
        assertEq(token.balanceOf(owner), 0);
        assertEq(owner.balance, 10 ether - LIQUIDITY_ETH);
        assertEq(token.balanceOf(address(l)), 0);
        assertEq(ILiquidityTestPair(pair).balanceOf(address(l)), 0);
        assertEq(weth.balanceOf(address(l)), 0);
        assertEq(address(l).balance, 0);
        assertEq(token.allowance(owner, address(l)), 0);
        assertEq(token.allowance(address(l), address(sablier)), 0);

        // Trading is open at the launch taxes, with the 2% max wallet on and the protocol in place.
        assertEq(token.buyTaxBps(), 500);
        assertEq(token.sellTaxBps(), 1_000);
        assertTrue(token.maxWalletActive());
        assertEq(token.reserve(), address(p.reserve()));
    }

    /// The Sablier call itself, in full: from the launch (not from the contract's deployment a day
    /// earlier), shape "cliff", nothing unlocked at the start or the cliff, one-second granularity,
    /// no ETH; funded by the liquidity contract, the owner named as the stream's sender.
    function test_the_stream_starts_at_the_launch_in_sablier_s_cliff_shape() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        vm.warp(LAUNCH_AT);
        ISablierLockup.CreateWithTimestamps memory params = ISablierLockup.CreateWithTimestamps({
            sender: owner,
            recipient: team,
            depositAmount: TEAM_STREAM,
            token: IERC20(address(token)),
            cancelable: false,
            transferable: false,
            timestamps: ISablierLockup.Timestamps({start: LAUNCH_AT, end: END_AT}),
            shape: "cliff"
        });
        vm.expectCall(
            address(sablier),
            0,
            abi.encodeCall(
                ISablierLockup.createWithTimestampsLL,
                (params, ISablierLockup.UnlockAmounts({start: 0, cliff: 0}), 0, CLIFF_AT)
            ),
            1
        );
        vm.expectCall(
            address(token), abi.encodeCall(IERC20.transferFrom, (address(l), address(sablier), uint256(TEAM_STREAM)))
        );
        _approveAndLaunch(l);
        assertEq(uint256(CLIFF_AT), Months.add(LAUNCH_AT, l.CLIFF_MONTHS()));
        assertEq(uint256(END_AT), Months.add(LAUNCH_AT, l.STREAM_MONTHS()));
    }

    /// Nothing unlocks before the cliff; from it the stream runs linearly to the end, where the team
    /// wallet can take all of it.
    function test_the_team_unlocks_nothing_before_the_cliff_and_all_of_it_at_18_months() public {
        (, KyzenLiquidity l) = _launched();
        uint256 id = l.streamId();
        vm.warp(CLIFF_AT - 1);
        assertEq(uint256(sablier.streamedAmountOf(id)), 0);
        vm.warp(Months.add(LAUNCH_AT, 12));
        assertApproxEqRel(uint256(sablier.streamedAmountOf(id)), uint256(TEAM_STREAM) / 2, 0.01e18);
        vm.warp(END_AT);
        assertEq(uint256(sablier.streamedAmountOf(id)), TEAM_STREAM);
        vm.prank(team);
        sablier.withdraw(id, team, TEAM_STREAM);
        assertEq(token.balanceOf(team), TEAM_STREAM);
    }

    function test_an_empty_team_wallet_is_the_owner() public {
        _protocol();
        KyzenLiquidity l = _liquidity(address(0));
        assertEq(l.teamWallet(), owner);
        _approveAndLaunch(l);
        assertEq(sablier.getRecipient(l.streamId()), owner);
        assertEq(sablier.getSender(l.streamId()), owner);
    }

    function test_the_contract_holds_its_settings_until_the_launch() public {
        KyzenLiquidity l = _liquidity(team);
        assertEq(address(l.token()), address(token));
        assertEq(l.pair(), pair);
        assertEq(address(l.sablier()), address(sablier));
        assertEq(l.owner(), owner);
        assertEq(l.teamWallet(), team);
        assertEq(l.liquidityEth(), LIQUIDITY_ETH);
        assertFalse(l.launched());
        assertEq(l.streamId(), 0);
        assertEq(l.lpTokens(), 0);
        // SPEC 3.1's split of the whole supply: 10% streamed to the team, 90% in the pool.
        assertEq(uint256(l.TEAM_STREAM()), SUPPLY / 10);
        assertEq(l.LIQUIDITY_KYZN(), SUPPLY * 9 / 10);
        assertEq(uint256(l.TEAM_STREAM()) + l.LIQUIDITY_KYZN(), token.INITIAL_SUPPLY());
        assertEq(l.CLIFF_MONTHS(), 6);
        assertEq(l.STREAM_MONTHS(), 18);
    }

    function test_the_launch_event_names_the_owner_the_stream_and_the_lp_tokens() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        vm.prank(owner);
        token.approve(address(l), SUPPLY);
        vm.expectEmit(true, true, true, true, address(l));
        emit KyzenLiquidity.Launched(owner, 1, _lp(LIQUIDITY_KYZN, LIQUIDITY_ETH));
        vm.prank(owner);
        l.launch{value: LIQUIDITY_ETH}();
    }

    /// No one can buy before the launch: the pool is empty until `launch` fills it.
    function test_trading_starts_with_the_launch() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        address[] memory path = _path(address(weth), address(token));
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(bytes("UniswapV2Library: INSUFFICIENT_LIQUIDITY"));
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(0, path, buyer, block.timestamp);
        _approveAndLaunch(l);
        assertGt(_buy(buyer, 0.01 ether), 0);
    }

    // ---------------------------------------------------------------- refusals

    /// Only the token's owner deploys it: not a stranger, and no one once the token is renounced,
    /// the former owner included.
    function test_only_the_token_s_owner_can_deploy_it() public {
        KyzenLiquidity.Setup memory s = _liquiditySetup(team);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KyzenLiquidity.NotTokenOwner.selector, owner));
        new KyzenLiquidity(s);

        vm.prank(owner);
        token.renounceOwnership();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KyzenLiquidity.NotTokenOwner.selector, address(0)));
        new KyzenLiquidity(s);
    }

    function test_only_the_owner_can_launch() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        vm.prank(owner);
        token.approve(address(l), SUPPLY);
        address[2] memory others = [stranger, team];
        for (uint256 i; i < others.length; ++i) {
            vm.deal(others[i], LIQUIDITY_ETH);
            vm.prank(others[i]);
            vm.expectRevert(KyzenLiquidity.NotOwner.selector);
            l.launch{value: LIQUIDITY_ETH}();
        }
        assertFalse(l.launched());
    }

    function test_the_launch_runs_once() public {
        (, KyzenLiquidity l) = _launched();
        vm.prank(owner);
        vm.expectRevert(KyzenLiquidity.AlreadyLaunched.selector);
        l.launch{value: LIQUIDITY_ETH}();
    }

    function test_the_launch_takes_exactly_2_eth() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        uint256[4] memory wrong = [uint256(0), LIQUIDITY_ETH - 1, LIQUIDITY_ETH + 1, 3 ether];
        vm.startPrank(owner);
        token.approve(address(l), SUPPLY);
        for (uint256 i; i < wrong.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(KyzenLiquidity.WrongValue.selector, LIQUIDITY_ETH, wrong[i]));
            l.launch{value: wrong[i]}();
        }
        l.launch{value: LIQUIDITY_ETH}();
        vm.stopPrank();
        assertTrue(l.launched());
        assertEq(owner.balance, 10 ether - LIQUIDITY_ETH);
    }

    /// The token's Reserve, Staking and Gateway must be set first (step two): with no protocol, and
    /// with it deployed but not yet set in the token, the launch is refused.
    function test_the_launch_waits_for_the_protocol_to_be_set_in_the_token() public {
        KyzenLiquidity l = _liquidity(team);
        vm.prank(owner);
        token.approve(address(l), SUPPLY);
        vm.prank(owner);
        vm.expectRevert(KyzenLiquidity.ProtocolNotSet.selector);
        l.launch{value: LIQUIDITY_ETH}();

        KyzenProtocol p = _deployProtocol();
        vm.prank(owner);
        vm.expectRevert(KyzenLiquidity.ProtocolNotSet.selector);
        l.launch{value: LIQUIDITY_ETH}();

        _setProtocol(p);
        vm.prank(owner);
        l.launch{value: LIQUIDITY_ETH}();
        assertTrue(l.launched());
    }

    /// Someone holding $KYZN (here, some the owner gave away) adds the first liquidity at a price of
    /// their own: the launch refuses the pool rather than add to it at that price.
    function test_a_pool_someone_priced_first_stops_the_launch() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        address early = makeAddr("early");
        vm.prank(owner);
        assertTrue(token.transfer(early, 1_000_000e18));
        vm.deal(early, 1 ether);
        vm.startPrank(early);
        weth.deposit{value: 1 ether}();
        assertTrue(token.transfer(pair, 1_000_000e18));
        assertTrue(weth.transfer(pair, 1 ether));
        ILiquidityTestPair(pair).mint(early);
        vm.stopPrank();
        assertGt(ILiquidityTestPair(pair).totalSupply(), 0);

        vm.startPrank(owner);
        token.approve(address(l), SUPPLY);
        vm.expectRevert(KyzenLiquidity.PoolAlreadyStarted.selector);
        l.launch{value: LIQUIDITY_ETH}();
        vm.stopPrank();
    }

    function test_the_launch_needs_the_owner_s_approval_for_the_whole_supply() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        vm.startPrank(owner);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(l), 0, SUPPLY));
        l.launch{value: LIQUIDITY_ETH}();
        token.approve(address(l), SUPPLY - 1);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, address(l), SUPPLY - 1, SUPPLY)
        );
        l.launch{value: LIQUIDITY_ETH}();
        token.approve(address(l), SUPPLY);
        l.launch{value: LIQUIDITY_ETH}();
        vm.stopPrank();
        assertTrue(l.launched());
    }

    function test_the_launch_needs_the_whole_supply_in_the_owner_s_wallet() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        vm.startPrank(owner);
        assertTrue(token.transfer(team, 1));
        token.approve(address(l), SUPPLY);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, owner, SUPPLY - 1, SUPPLY)
        );
        l.launch{value: LIQUIDITY_ETH}();
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- a pair touched before the launch

    /// Anyone can send WETH to the empty pair and sync it. Router02 then refuses the first
    /// liquidity (its quote needs both reserves), which is why the contract adds it by transfer and
    /// `mint`: the launch goes through untaxed, and every LP token but Uniswap's 1,000 is the
    /// owner's, the pool's extra wei included.
    function test_a_pair_sent_1_wei_of_weth_and_synced_still_launches() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        address griefer = makeAddr("griefer");
        vm.deal(griefer, 1);
        vm.startPrank(griefer);
        weth.deposit{value: 1}();
        assertTrue(weth.transfer(pair, 1));
        ILiquidityTestPair(pair).sync();
        vm.stopPrank();
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, 0);
        assertEq(ethReserve, 1);

        vm.startPrank(owner);
        token.approve(address(router), LIQUIDITY_KYZN);
        vm.expectRevert(bytes("UniswapV2Library: INSUFFICIENT_LIQUIDITY"));
        router.addLiquidityETH{value: LIQUIDITY_ETH}(address(token), LIQUIDITY_KYZN, 0, 0, owner, block.timestamp);
        token.approve(address(router), 0);
        token.approve(address(l), SUPPLY);
        l.launch{value: LIQUIDITY_ETH}();
        vm.stopPrank();

        (kyznReserve, ethReserve) = _reserves();
        assertEq(kyznReserve, LIQUIDITY_KYZN);
        assertEq(ethReserve, LIQUIDITY_ETH + 1);
        // `mint` counts what arrived above the synced reserves: the 900,000,000 $KYZN and the 2 ETH.
        uint256 lp = _lp(LIQUIDITY_KYZN, LIQUIDITY_ETH);
        assertEq(l.lpTokens(), lp);
        assertEq(ILiquidityTestPair(pair).balanceOf(owner), lp);
        assertEq(ILiquidityTestPair(pair).totalSupply(), lp + MINIMUM_LIQUIDITY);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(uint256(token.reserveTaxTokens()), 0);
        assertEq(uint256(token.stakingTaxTokens()), 0);
        assertEq(address(l).balance, 0);
    }

    /// WETH sent to the pair and not synced is counted by `mint` with the owner's: it joins the
    /// pool, and its LP goes to the owner with the rest.
    function test_weth_sent_to_the_pair_ahead_joins_the_owner_s_liquidity() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        address donor = makeAddr("donor");
        vm.deal(donor, 1 ether);
        vm.startPrank(donor);
        weth.deposit{value: 1 ether}();
        assertTrue(weth.transfer(pair, 1 ether));
        vm.stopPrank();

        _approveAndLaunch(l);
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, LIQUIDITY_KYZN);
        assertEq(ethReserve, LIQUIDITY_ETH + 1 ether);
        uint256 lp = _lp(LIQUIDITY_KYZN, LIQUIDITY_ETH + 1 ether);
        assertEq(l.lpTokens(), lp);
        assertEq(ILiquidityTestPair(pair).balanceOf(owner), lp);
        assertEq(token.balanceOf(address(token)), 0);
    }

    // ---------------------------------------------------------------- trading after the launch

    /// The first buy pays 5% and the sell of everything it bought 10%, exactly; each records the
    /// Reserve's 2 points and Staking's 1 point of its own trade, 2 : 1.
    function test_after_the_launch_a_buy_pays_5_percent_and_a_sell_10() public {
        _launched();
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        uint256 gross = _amountOut(0.01 ether, ethReserve, kyznReserve);
        uint256 bought = _buy(buyer, 0.01 ether);
        uint256 buyTax = gross * 500 / 10_000;
        assertEq(bought, gross - buyTax);
        assertEq(token.balanceOf(address(token)), buyTax);
        assertEq(uint256(token.reserveTaxTokens()), buyTax * 200 / 500);
        assertEq(uint256(token.stakingTaxTokens()), buyTax * 100 / 500);

        // Below the swap threshold, so no tax sale runs before the sell.
        assertLt(buyTax, token.swapThreshold());
        (kyznReserve, ethReserve) = _reserves();
        uint256 sellTax = bought * 1_000 / 10_000;
        uint256 expectedEth = _amountOut(bought - sellTax, kyznReserve, ethReserve);
        assertEq(_sell(buyer, bought), expectedEth);
        assertEq(token.balanceOf(buyer), 0);
        assertEq(token.balanceOf(address(token)), buyTax + sellTax);
        uint256 toReserve = buyTax * 200 / 500 + sellTax * 200 / 1_000;
        uint256 toStaking = buyTax * 100 / 500 + sellTax * 100 / 1_000;
        assertEq(uint256(token.reserveTaxTokens()), toReserve);
        assertEq(uint256(token.stakingTaxTokens()), toStaking);
        assertApproxEqAbs(toReserve, 2 * toStaking, 2);
    }

    /// Once the tax held reaches the swap threshold, the next sell first sells it for ETH and pays
    /// the Reserve and Staking their recorded shares in the same transaction; development's share
    /// is held for its wallet (the owner's) until anyone sends it.
    function test_a_tax_sale_pays_the_reserve_and_staking() public {
        (KyzenProtocol p,) = _launched();
        _buy(buyer, 0.04 ether);
        uint256 pending = token.balanceOf(address(token));
        assertGe(pending, token.swapThreshold());
        uint256 reserveTokens = token.reserveTaxTokens();
        uint256 stakingTokens = token.stakingTaxTokens();
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        // All of it sells: it is below the sell and below 0.25% of the pool's $KYZN.
        uint256 sellAmount = 1_000_000e18;
        assertLt(pending, sellAmount);
        assertLt(pending, kyznReserve * 25 / 10_000);
        uint256 received = _amountOut(pending, kyznReserve, ethReserve);
        uint256 toReserve = received * reserveTokens / pending;
        uint256 toStaking = received * stakingTokens / pending;
        uint256 toDevelopment = received - toReserve - toStaking;

        vm.startPrank(buyer);
        token.approve(address(router), sellAmount);
        vm.expectEmit(address(token));
        emit KyznToken.TaxSwapped(pending, received);
        vm.expectEmit(address(token));
        emit KyznToken.TaxDistributed(toReserve, toStaking, toDevelopment);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            sellAmount, 0, _path(address(token), address(weth)), buyer, block.timestamp
        );
        vm.stopPrank();
        assertGt(toReserve, 0);
        assertGt(toStaking, 0);
        assertEq(address(p.reserve()).balance, toReserve);
        assertEq(address(p.staking()).balance, toStaking);
        assertEq(token.heldEth(owner), toDevelopment);
        // What stays held and recorded: the sell's own 10%.
        uint256 sellTax = sellAmount / 10;
        assertEq(token.balanceOf(address(token)), sellTax);
        assertEq(uint256(token.reserveTaxTokens()), sellTax * 200 / 1_000);
        assertEq(uint256(token.stakingTaxTokens()), sellTax * 100 / 1_000);

        uint256 before = owner.balance;
        vm.prank(stranger);
        token.sendHeldEth(owner);
        assertEq(owner.balance - before, toDevelopment);
    }

    /// A buy that would leave a wallet above 2% of supply reverts inside the pair's transfer, which
    /// Uniswap reports as its own TRANSFER_FAILED, the first buy as well as one that tops a wallet up.
    function test_the_max_wallet_holds_on_buys() public {
        _launched();
        assertTrue(token.maxWalletActive());
        address[] memory path = _path(address(weth), address(token));
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        uint256 gross = _amountOut(0.1 ether, ethReserve, kyznReserve);
        assertGt(gross - gross * 500 / 10_000, token.MAX_WALLET());
        vm.deal(buyer, 1 ether);
        vm.prank(buyer);
        vm.expectRevert(bytes("UniswapV2: TRANSFER_FAILED"));
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.1 ether}(0, path, buyer, block.timestamp);
        assertEq(token.balanceOf(buyer), 0);

        uint256 held = _buy(buyer, 0.04 ether);
        assertLe(held, token.MAX_WALLET());
        (kyznReserve, ethReserve) = _reserves();
        gross = _amountOut(0.01 ether, ethReserve, kyznReserve);
        assertGt(held + gross - gross * 500 / 10_000, token.MAX_WALLET());
        vm.prank(buyer);
        vm.expectRevert(bytes("UniswapV2: TRANSFER_FAILED"));
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(0, path, buyer, block.timestamp);
        assertEq(token.balanceOf(buyer), held);
    }

    // ---------------------------------------------------------------- the mainnet contract

    function test_the_mainnet_liquidity_runs_only_on_robinhood_chain() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, block.chainid));
        new KyzenMainnetLiquidity(token, team);
    }

    function test_the_mainnet_liquidity_refuses_a_token_on_another_router() public {
        vm.chainId(RobinhoodChain.CHAIN_ID);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(NotRobinhoodToken.selector, address(router)));
        new KyzenMainnetLiquidity(token, team);
    }

    /// The three mainnet steps with the mainnet contracts' own setups, offline: on chain ID 4663,
    /// with this test's Router02, Sablier stand-in, feeds and stock tokens standing at their
    /// Robinhood Chain addresses (their code placed there). test/fork runs them against the real
    /// contracts.
    function test_the_three_mainnet_steps_on_robinhood_chain_s_addresses() public {
        KyznToken t = _robinhoodChain();
        TestnetSablierLockup lockup = TestnetSablierLockup(RobinhoodChain.SABLIER_LOCKUP);
        IUniswapV2Router02 rhRouter = IUniswapV2Router02(RobinhoodChain.UNISWAP_V2_ROUTER);

        vm.startPrank(owner);
        KyzenMainnetProtocol p = new KyzenMainnetProtocol(t, address(0), MAINNET_KEEPER, MAINNET_OPERATOR);
        t.setProtocolAddresses(address(p.reserve()), address(p.staking()), address(p.gateway()));
        p.registry().acceptOwnership();
        p.reserve().acceptOwnership();
        p.staking().acceptOwnership();
        p.gateway().acceptOwnership();
        KyzenMainnetLiquidity unused = new KyzenMainnetLiquidity(t, address(0));
        KyzenMainnetLiquidity l = new KyzenMainnetLiquidity(t, team);
        t.approve(address(l), SUPPLY);
        l.launch{value: LIQUIDITY_ETH}();
        vm.stopPrank();

        assertEq(unused.teamWallet(), owner); // zero argument: the deploying owner
        assertEq(l.liquidityEth(), 2 ether);
        assertEq(address(l.sablier()), RobinhoodChain.SABLIER_LOCKUP);
        assertEq(l.teamWallet(), team);

        (uint256 kyznReserve, uint256 ethReserve) = _reservesOf(t);
        assertEq(kyznReserve, LIQUIDITY_KYZN);
        assertEq(ethReserve, LIQUIDITY_ETH);
        assertEq(l.lpTokens(), _lp(LIQUIDITY_KYZN, LIQUIDITY_ETH));
        assertEq(ILiquidityTestPair(t.pair()).balanceOf(owner), l.lpTokens());

        uint256 id = l.streamId();
        assertEq(id, 1);
        assertEq(lockup.getRecipient(id), team);
        assertEq(lockup.getSender(id), owner);
        assertEq(uint256(lockup.getDepositedAmount(id)), TEAM_STREAM);
        assertEq(uint256(lockup.getCliffTime(id)), Months.add(block.timestamp, 6));
        assertEq(uint256(lockup.getEndTime(id)), Months.add(block.timestamp, 18));
        assertFalse(lockup.isCancelable(id));
        assertFalse(lockup.isTransferable(id));
        assertEq(t.balanceOf(address(lockup)), TEAM_STREAM);
        assertEq(t.balanceOf(owner), 0);

        // A first buy through Router02 at its mainnet address pays the 5% buy tax.
        uint256 gross = _amountOut(0.01 ether, ethReserve, kyznReserve);
        vm.deal(buyer, 0.01 ether);
        vm.prank(buyer);
        rhRouter.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(
            0, _path(address(weth), address(t)), buyer, block.timestamp
        );
        assertEq(t.balanceOf(buyer), gross - gross * 500 / 10_000);
        assertEq(t.balanceOf(address(t)), gross * 500 / 10_000);
    }

    /// Chain ID 4663, with this test's Router02 at Router02's address there (its factory and WETH
    /// are this test's), the Sablier stand-in at Sablier Lockup's (its first stream ID 1, as its
    /// constructor sets it), a feed's code at each feed address and a stock token's at each stock
    /// token address; then the owner deploys the token on that Router02, as in step one.
    function _robinhoodChain() internal returns (KyznToken t) {
        vm.etch(RobinhoodChain.UNISWAP_V2_ROUTER, address(router).code);
        vm.etch(RobinhoodChain.SABLIER_LOCKUP, address(sablier).code);
        vm.store(RobinhoodChain.SABLIER_LOCKUP, bytes32(0), bytes32(uint256(1)));
        assertEq(TestnetSablierLockup(RobinhoodChain.SABLIER_LOCKUP).nextStreamId(), 1);
        bytes memory feedCode = address(new MockFeed(8, 100e8)).code;
        bytes memory stockCode = address(new MockStockToken("STOCK")).code;
        vm.etch(RobinhoodChain.ETH_USD_FEED, feedCode);
        RobinhoodChain.Asset[7] memory list = RobinhoodChain.assets();
        for (uint256 i; i < list.length; ++i) {
            vm.etch(list[i].token, stockCode);
            vm.etch(list[i].feed, feedCode);
        }
        vm.chainId(RobinhoodChain.CHAIN_ID);
        vm.prank(owner);
        t = new KyznToken(IUniswapV2Router02(RobinhoodChain.UNISWAP_V2_ROUTER), owner);
        assertEq(t.weth(), address(weth));
    }

    // ---------------------------------------------------------------- the review's fixes

    /// ETH sent ahead to the address the liquidity contract will get (it follows from the owner's
    /// transaction count) once stopped every launch; now it goes to the owner with the launch.
    function test_eth_sent_ahead_to_the_liquidity_address_goes_to_the_owner() public {
        _protocol();
        address predicted = vm.computeCreateAddress(owner, vm.getNonce(owner));
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = predicted.call{value: 1 wei}("");
        assertTrue(ok, "a plain address takes ETH");
        KyzenLiquidity l = _liquidity(team);
        assertEq(address(l), predicted);
        assertEq(address(l).balance, 1 wei);
        vm.warp(LAUNCH_AT);
        uint256 before = owner.balance;
        _approveAndLaunch(l);
        assertTrue(l.launched());
        assertEq(address(l).balance, 0, "nothing stays");
        assertEq(owner.balance, before - LIQUIDITY_ETH + 1 wei, "the owner gets the extra wei back");
    }

    /// ETH forced in after the deployment (SELFDESTRUCT sends it to a contract without receive;
    /// vm.deal stands in for it) cannot stop the launch either.
    function test_eth_forced_in_after_the_deployment_goes_to_the_owner() public {
        _protocol();
        KyzenLiquidity l = _liquidity(team);
        vm.deal(address(l), 0.5 ether);
        assertEq(address(l).balance, 0.5 ether);
        vm.warp(LAUNCH_AT);
        uint256 before = owner.balance;
        _approveAndLaunch(l);
        assertTrue(l.launched());
        assertEq(address(l).balance, 0);
        assertEq(owner.balance, before - LIQUIDITY_ETH + 0.5 ether);
    }

    /// Trading starts only with protocol contracts the owner owns: before the four are accepted
    /// the launch refuses, after it goes through.
    function test_the_launch_waits_for_the_owner_to_accept_the_protocol() public {
        KyzenProtocol p = _deployProtocol();
        (address reserve, address staking, address gateway) =
            (address(p.reserve()), address(p.staking()), address(p.gateway()));
        vm.prank(owner);
        token.setProtocolAddresses(reserve, staking, gateway);
        KyzenLiquidity l = _liquidity(team);
        vm.warp(LAUNCH_AT);
        vm.prank(owner);
        token.approve(address(l), SUPPLY);
        vm.prank(owner);
        vm.expectRevert(KyzenLiquidity.ProtocolNotOwned.selector);
        l.launch{value: LIQUIDITY_ETH}();

        vm.startPrank(owner);
        p.reserve().acceptOwnership();
        p.staking().acceptOwnership();
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(KyzenLiquidity.ProtocolNotOwned.selector);
        l.launch{value: LIQUIDITY_ETH}();

        GatewaySettlementLike g = GatewaySettlementLike(gateway);
        vm.prank(owner);
        g.acceptOwnership();
        vm.prank(owner);
        l.launch{value: LIQUIDITY_ETH}();
        assertTrue(l.launched());
    }

    /// Contracts a stranger built for this token and the owner set in it by mistake can never be
    /// the ones trading starts with.
    function test_a_stranger_built_protocol_never_starts_trading() public {
        // Only the token's owner can deploy KyzenProtocol, so the stranger's set is built directly.
        KyzenProtocol mine = _deployProtocol();
        vm.startPrank(stranger);
        GatewaySettlementLike strangerGateway = GatewaySettlementLike(
            deployCode("GatewaySettlement.sol:GatewaySettlement", abi.encode(address(token), address(router), stranger))
        );
        vm.stopPrank();
        vm.startPrank(owner);
        token.setProtocolAddresses(address(mine.reserve()), address(mine.staking()), address(strangerGateway));
        mine.reserve().acceptOwnership();
        mine.staking().acceptOwnership();
        vm.stopPrank();
        assertEq(strangerGateway.owner(), stranger);
        KyzenLiquidity l = _liquidity(team);
        vm.warp(LAUNCH_AT);
        vm.prank(owner);
        token.approve(address(l), SUPPLY);
        vm.prank(owner);
        vm.expectRevert(KyzenLiquidity.ProtocolNotOwned.selector);
        l.launch{value: LIQUIDITY_ETH}();
    }

    /// A stream to an address the team can never withdraw from is refused at the deployment.
    function test_the_team_wallet_cannot_be_a_system_address() public {
        address[5] memory bad = [address(token), pair, token.weth(), address(router), address(sablier)];
        for (uint256 i; i < bad.length; ++i) {
            KyzenLiquidity.Setup memory s = _liquiditySetup(bad[i]);
            vm.prank(owner);
            vm.expectRevert(KyzenLiquidity.BadTeamWallet.selector);
            new KyzenLiquidity(s);
        }
        // Its own address, which the owner's transaction count gives in advance.
        KyzenLiquidity.Setup memory self = _liquiditySetup(vm.computeCreateAddress(owner, vm.getNonce(owner)));
        vm.prank(owner);
        vm.expectRevert(KyzenLiquidity.BadTeamWallet.selector);
        new KyzenLiquidity(self);
    }

    /// The owner wallet must take back ETH sent ahead; one that refuses it stops the launch, and
    /// nothing moves.
    function test_an_owner_that_refuses_eth_stops_the_launch_with_eth_sent_ahead() public {
        RefusingOwner refusing = new RefusingOwner();
        vm.deal(address(refusing), 10 ether);
        vm.prank(owner);
        token.transferOwnership(address(refusing));
        vm.prank(address(refusing));
        token.acceptOwnership();
        vm.prank(owner);
        assertTrue(token.transfer(address(refusing), SUPPLY));
        // Step two from the refusing owner.
        KyzenProtocol.Setup memory s;
        s.token = token;
        s.ethUsdFeed = ethUsd;
        s.assets = assetList;
        s.equityAssetA = assetList[0].token;
        s.equityAssetB = assetList[1].token;
        s.swapTarget = address(0x5a9);
        s.keeper = keeper;
        s.operator = operator;
        vm.startPrank(address(refusing));
        KyzenProtocol p = new KyzenProtocol(s);
        token.setProtocolAddresses(address(p.reserve()), address(p.staking()), address(p.gateway()));
        p.registry().acceptOwnership();
        p.reserve().acceptOwnership();
        p.staking().acceptOwnership();
        p.gateway().acceptOwnership();
        KyzenLiquidity l = new KyzenLiquidity(_liquiditySetup(team));
        vm.stopPrank();
        vm.deal(address(l), 1 wei);
        vm.warp(LAUNCH_AT);
        vm.startPrank(address(refusing));
        token.approve(address(l), SUPPLY);
        vm.expectRevert(KyzenLiquidity.RefundFailed.selector);
        l.launch{value: LIQUIDITY_ETH}();
        vm.stopPrank();
        assertFalse(l.launched());
        assertEq(token.balanceOf(address(refusing)), SUPPLY);
    }
}

/// An owner contract that takes no ETH.
contract RefusingOwner {
    receive() external payable {
        revert("no ETH");
    }
}

/// The settlement contract's ownership, as the tests use it.
interface GatewaySettlementLike {
    function owner() external view returns (address);
    function acceptOwnership() external;
}
