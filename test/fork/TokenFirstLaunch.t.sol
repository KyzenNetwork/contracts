// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {WeightRegistry} from "../../src/WeightRegistry.sol";
import {Reserve} from "../../src/Reserve.sol";
import {Staking} from "../../src/Staking.sol";
import {GatewaySettlement} from "../../src/GatewaySettlement.sol";
import {IUniswapV2Factory, IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {KyzenProtocol, KyzenMainnetProtocol} from "../../script/KyzenProtocol.sol";
import {KyzenLiquidity, KyzenMainnetLiquidity} from "../../script/KyzenLiquidity.sol";
import {RecordMainnet} from "../../script/RecordMainnet.s.sol";
import {Months} from "../../script/lib/Months.sol";
import {ISablierLockup} from "../../script/interfaces/ISablierLockup.sol";
import {IUniswapV2Locker} from "../../script/interfaces/IUniswapV2Locker.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";

/// The real $KYZN/WETH pair, as far as these tests use it.
interface IKyznPair {
    function getReserves() external view returns (uint112, uint112, uint32);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
    function sync() external;
}

/// Sablier Lockup v4.0 views that script/interfaces/ISablierLockup.sol leaves out; each selector is
/// in the code deployed on Robinhood Chain.
interface ISablierLockupViews {
    function nextStreamId() external view returns (uint256);
    function getStartTime(uint256 streamId) external view returns (uint40 startTime);
    function getUnderlyingToken(uint256 streamId) external view returns (IERC20 token);
    function getUnlockAmounts(uint256 streamId) external view returns (uint128 start, uint128 cliff);
    function ownerOf(uint256 streamId) external view returns (address);
}

/// A call that does nothing, to tell whether forge runs each call as a transaction of its own.
contract IsolationProbe {
    function ping() external {}
}

/// The owner's launch on the real deployed $KYZN token (SPEC 3.1), rehearsed on a fork of Robinhood
/// Chain mainnet. Step one is on chain: the owner wallet deployed KyznToken alone, owns it directly,
/// holds all 1,000,000,000 $KYZN and is the development wallet; the pair exists and is empty. These
/// tests run the owner's next transactions exactly as the owner sends them, from the real owner
/// wallet:
///   step two: deploy KyzenMainnetProtocol(token, 0, KEEPER, OPERATOR), call the token's
///     setProtocolAddresses, then acceptOwnership on the registry, the Reserve, Staking and the
///     Gateway;
///   step three: deploy KyzenMainnetLiquidity(token, team wallet), approve it for 1,000,000,000
///     $KYZN, call launch with 2 ETH;
/// then trading, the owner's UNCX lock by hand, and what anyone can do to the empty pair before
/// step three. Every other contract is Robinhood Chain's own: Uniswap v2, WETH, Sablier Lockup
/// v4.0, UNCX's V2 locker, the stock tokens and their Chainlink feeds; KEEPER and OPERATOR are the
/// server's real wallets. Buyers and helpers are fresh addresses: on Robinhood Chain mainnet,
/// anvil's well-known default accounts carry an EIP-7702 delegation that sweeps incoming ETH.
///
/// The fork is KYZEN_FORK_URL (default: the local serial forwarder, http://127.0.0.1:8554) at its
/// latest block. It rehearses the chain as it stands before step two: once the token has protocol
/// addresses or the pair has liquidity tokens on mainnet, every test is skipped.
///
/// Gas: each owner transaction's gas is logged by test_3a and test_3b. Run them with
/// `forge test --isolate` for the gas each receipt shows, before Robinhood Chain's data fee;
/// without --isolate the figures are estimates.
contract TokenFirstLaunchForkTest is Test {
    KyznToken internal constant TOKEN = KyznToken(payable(0x9b3A765a32F3ff0623a2dEa04136960C77205B09));
    address internal constant OWNER = 0x965200078d41c1B91CED2f842106662d8bDdd16e;
    address internal constant PAIR = 0x49449B585e5D05f3aCFF985c4978147FA0593665;
    /// The server's wallets for step two.
    address internal constant KEEPER = 0x9773407713fe52BfF54C5E3f519A5EA4F7334538;
    address internal constant OPERATOR = 0x2Ba4C980AaCcd4896d8418960D26400259C839Bb;

    IKyznPair internal constant POOL = IKyznPair(PAIR);
    IUniswapV2Router02 internal constant ROUTER = IUniswapV2Router02(RH.UNISWAP_V2_ROUTER);
    ISablierLockup internal constant SABLIER = ISablierLockup(RH.SABLIER_LOCKUP);
    ISablierLockupViews internal constant SABLIER_VIEWS = ISablierLockupViews(RH.SABLIER_LOCKUP);
    IUniswapV2Locker internal constant LOCKER = IUniswapV2Locker(RH.UNCX_V2_LOCKER);

    uint256 internal constant SUPPLY = 1_000_000_000e18;
    uint256 internal constant TEAM_STREAM = 100_000_000e18;
    uint256 internal constant LIQUIDITY_KYZN = 900_000_000e18;
    uint256 internal constant LIQUIDITY_ETH = 2 ether;
    uint256 internal constant MINIMUM_LIQUIDITY = 1_000;
    /// The country code UNCX's app sends for every lock on this locker ("Other" in UNCX's list).
    uint16 internal constant UNCX_APP_COUNTRY = 0;

    /// The gas of the owner's nine transactions, in the order the owner sends them.
    struct OwnerGas {
        uint256 protocolDeploy;
        uint256 setProtocolAddresses;
        uint256 acceptRegistry;
        uint256 acceptReserve;
        uint256 acceptStaking;
        uint256 acceptGateway;
        uint256 liquidityDeploy;
        uint256 approve;
        uint256 launch;
    }

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

    address internal team = makeAddr("team");

    /// The owner wallet's ETH on chain at the fork block, before the test's top-up.
    uint256 internal ownerEthOnChain;
    OwnerGas internal ownerGas;
    IsolationProbe internal probe;

    KyzenMainnetProtocol internal protocol;
    WeightRegistry internal registry;
    Reserve internal reserve;
    Staking internal staking;
    GatewaySettlement internal gateway;
    KyzenMainnetLiquidity internal liquidity;

    function setUp() public {
        vm.createSelectFork(vm.envOr("KYZEN_FORK_URL", string("http://127.0.0.1:8554")));
        assertEq(block.chainid, RH.CHAIN_ID, "the fork is not Robinhood Chain mainnet");
        if (TOKEN.reserve() != address(0) || POOL.totalSupply() != 0) {
            vm.skip(true, "step two or three already ran on mainnet: nothing left to rehearse");
        }
        ownerEthOnChain = OWNER.balance;
        // The 2 ETH of liquidity and the UNCX fee, on top of what the owner wallet holds.
        vm.deal(OWNER, ownerEthOnChain + 10 ether);
        probe = new IsolationProbe();
    }

    // ---------------------------------------------------------------- 1. step one, on chain

    function test_1_the_real_token_is_as_step_one_left_it() public {
        emit log_named_uint("fork block", block.number);
        emit log_named_decimal_uint("owner wallet ETH on chain", ownerEthOnChain, 18);

        // The owner wallet owns the token directly and holds the whole supply.
        assertEq(TOKEN.owner(), OWNER);
        assertEq(TOKEN.pendingOwner(), address(0));
        assertEq(TOKEN.totalSupply(), SUPPLY);
        assertEq(TOKEN.balanceOf(OWNER), SUPPLY);
        assertEq(OWNER.code.length, 0);
        assertEq(KEEPER.code.length, 0);
        assertEq(OPERATOR.code.length, 0);

        // Built on Robinhood Chain's Router02, the owner wallet its development wallet, no protocol
        // addresses yet, the launch settings.
        assertEq(address(TOKEN.router()), RH.UNISWAP_V2_ROUTER);
        assertEq(TOKEN.weth(), RH.WETH);
        assertEq(TOKEN.devWallet(), OWNER);
        assertEq(TOKEN.reserve(), address(0));
        assertEq(TOKEN.staking(), address(0));
        assertEq(TOKEN.gateway(), address(0));
        assertEq(TOKEN.buyTaxBps(), 500);
        assertEq(TOKEN.sellTaxBps(), 1_000);
        assertEq(TOKEN.swapThreshold(), 500_000e18);
        assertTrue(TOKEN.maxWalletActive());
        assertGt(TOKEN.launchedAt(), 0);
        assertLe(TOKEN.launchedAt(), block.timestamp);
        _assertNoTax();

        // Its pair is the factory's $KYZN/WETH pair, and empty.
        assertEq(TOKEN.pair(), PAIR);
        assertEq(IUniswapV2Factory(RH.UNISWAP_V2_FACTORY).getPair(address(TOKEN), RH.WETH), PAIR);
        assertTrue(
            (POOL.token0() == RH.WETH && POOL.token1() == address(TOKEN))
                || (POOL.token0() == address(TOKEN) && POOL.token1() == RH.WETH)
        );
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, 0);
        assertEq(ethReserve, 0);
        assertEq(POOL.totalSupply(), 0);

        // Step three cannot run before step two, and the recorder refuses a token without its protocol.
        vm.startPrank(OWNER);
        KyzenMainnetLiquidity early = new KyzenMainnetLiquidity(TOKEN, address(0));
        TOKEN.approve(address(early), SUPPLY);
        vm.expectRevert(KyzenLiquidity.ProtocolNotSet.selector);
        early.launch{value: LIQUIDITY_ETH}();
        vm.stopPrank();
        RecordMainnet recorder = new RecordMainnet();
        vm.expectRevert(RecordMainnet.NotWired.selector);
        recorder.read(address(TOKEN));
    }

    // ---------------------------------------------------------------- 2. step two

    function test_2a_step_two_deploys_the_protocol_and_the_owner_sets_and_accepts_it() public {
        uint256 queuedAt = block.timestamp;
        vm.recordLogs();
        _deployProtocol();
        _assertDeployLogs(vm.getRecordedLogs(), queuedAt);

        // Offered to the owner wallet, not yet its own; the token does not know them yet.
        _assertOwners(address(protocol), OWNER);
        _assertProtocolSettings();
        assertEq(TOKEN.reserve(), address(0));
        assertFalse(reserve.isTargetAllowed(RH.UNISWAP_V3_SWAP_ROUTER_02));

        // The token takes the three addresses and exempts them; the owner wallet stays the
        // development wallet, and taxed.
        _setProtocolAddresses();
        assertEq(TOKEN.reserve(), address(reserve));
        assertEq(TOKEN.staking(), address(staking));
        assertEq(TOKEN.gateway(), address(gateway));
        assertTrue(TOKEN.isExempt(address(reserve)));
        assertTrue(TOKEN.isExempt(address(staking)));
        assertTrue(TOKEN.isExempt(address(gateway)));
        assertFalse(TOKEN.isExempt(OWNER));
        assertEq(TOKEN.devWallet(), OWNER);

        // The owner wallet accepts the four and owns them, as it owns the token.
        _acceptOwnership();
        _assertOwners(OWNER, address(0));
        assertEq(TOKEN.owner(), OWNER);
        assertEq(TOKEN.pendingOwner(), address(0));
        assertEq(registry.rotationCount(), 0);

        // The deployment contract keeps nothing.
        assertEq(address(protocol).balance, 0);
        assertEq(TOKEN.balanceOf(address(protocol)), 0);
        assertEq(TOKEN.balanceOf(OWNER), SUPPLY);
        _assertNoTax();

        // SwapRouter02 becomes the Reserve's swap target 24 hours after the deployment.
        vm.warp(queuedAt + 24 hours - 1);
        assertFalse(reserve.isTargetAllowed(RH.UNISWAP_V3_SWAP_ROUTER_02));
        vm.warp(queuedAt + 24 hours);
        assertTrue(reserve.isTargetAllowed(RH.UNISWAP_V3_SWAP_ROUTER_02));
    }

    /// RecordMainnet's read, the check its run() records with, on a deployed recorder: every address
    /// from the real token once the token has its protocol addresses, with the four still to accept,
    /// and again once accepted.
    function test_2b_record_mainnet_reads_every_address_from_the_real_token() public {
        RecordMainnet recorder = new RecordMainnet();
        _deployProtocol();
        _setProtocolAddresses();
        _assertRecord(recorder.read(address(TOKEN)));
        _acceptOwnership();
        _assertRecord(recorder.read(address(TOKEN)));
    }

    function test_2c_step_two_takes_only_the_token_owner_and_both_server_wallets() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KyzenProtocol.NotTokenOwner.selector, OWNER));
        new KyzenMainnetProtocol(TOKEN, address(0), KEEPER, OPERATOR);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(KyzenProtocol.SettingNotSet.selector, "KEEPER"));
        new KyzenMainnetProtocol(TOKEN, address(0), address(0), OPERATOR);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(KyzenProtocol.SettingNotSet.selector, "OPERATOR"));
        new KyzenMainnetProtocol(TOKEN, address(0), KEEPER, address(0));

        // Only the owner wallet sets the token's addresses and accepts the four.
        _deployProtocol();
        (address r, address s, address g) = (address(reserve), address(staking), address(gateway));
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        TOKEN.setProtocolAddresses(r, s, g);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        reserve.acceptOwnership();
    }

    // ---------------------------------------------------------------- 3. step three

    function test_3a_step_three_launches_with_the_owner_wallet_as_the_team_wallet() public {
        _stepTwo();
        _launchAndCheck(OWNER);
        _logOwnerGas();
    }

    function test_3b_step_three_launches_with_a_separate_team_wallet() public {
        _stepTwo();
        _launchAndCheck(team);
        _logOwnerGas();
    }

    function test_3c_step_three_takes_only_the_owner_and_exactly_2_eth() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KyzenLiquidity.NotTokenOwner.selector, OWNER));
        new KyzenMainnetLiquidity(TOKEN, team);

        _stepTwo();
        // A zero team wallet is the deploying wallet.
        _deployLiquidity(address(0));
        assertEq(liquidity.teamWallet(), OWNER);
        _approve();
        vm.deal(stranger, LIQUIDITY_ETH);
        vm.prank(stranger);
        vm.expectRevert(KyzenLiquidity.NotOwner.selector);
        liquidity.launch{value: LIQUIDITY_ETH}();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(KyzenLiquidity.WrongValue.selector, LIQUIDITY_ETH, 1 ether));
        liquidity.launch{value: 1 ether}();
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(KyzenLiquidity.WrongValue.selector, LIQUIDITY_ETH, 3 ether));
        liquidity.launch{value: 3 ether}();
        assertFalse(liquidity.launched());

        // None of that is in the way of the owner's own call.
        _launch();
        assertTrue(liquidity.launched());
        assertEq(SABLIER.getRecipient(liquidity.streamId()), OWNER);
    }

    // ---------------------------------------------------------------- 4. after the launch

    function test_4a_fresh_wallets_trade_at_the_launch_taxes_and_a_tax_sale_pays_the_protocol() public {
        _stepTwo();
        _stepThree(team);
        _roundTripPaysTheLaunchTaxes(makeAddr("buyer"));
        uint256 toDevelopment = _secondRoundTripSellsTheTax(makeAddr("seller"));
        _theServerSendsTheHeldEthToTheOwnerWallet(toDevelopment);
        _aBuyAboveTheMaxWalletReverts(makeAddr("whale"));
    }

    /// Right after the launch, from UNCX's app: every LP token for 6 months, the fee in ETH, no
    /// referral, the owner wallet as withdrawer, country code 0.
    function test_4b_the_owner_locks_every_lp_token_on_uncx_by_hand() public {
        _stepTwo();
        (, uint256 lp) = _stepThree(team);
        (uint256 ethFee,,,, uint256 lpFeePerMille,,,,) = LOCKER.gFees();
        emit log_named_decimal_uint("UNCX fee in ETH", ethFee, 18);
        emit log_named_uint("UNCX fee in LP, per mille", lpFeePerMille);
        assertEq(LOCKER.uniswapFactory(), RH.UNISWAP_V2_FACTORY);

        uint256 unlockDate = Months.add(block.timestamp, 6);
        uint256 ownerEth = OWNER.balance;
        vm.startPrank(OWNER);
        IERC20(PAIR).approve(address(LOCKER), lp);
        LOCKER.lockLPToken{value: ethFee}(
            PAIR, lp, unlockDate, payable(address(0)), true, payable(OWNER), UNCX_APP_COUNTRY
        );
        vm.stopPrank();

        uint256 locked = lp - lp * lpFeePerMille / 1000;
        assertEq(LOCKER.getUserNumLocksForToken(OWNER, PAIR), 1);
        IUniswapV2Locker.TokenLock memory lock = LOCKER.getUserLockForTokenAtIndex(OWNER, PAIR, 0);
        assertEq(lock.lpToken, PAIR);
        assertEq(lock.amount, locked);
        assertEq(lock.owner, OWNER);
        assertEq(lock.unlockDate, unlockDate);
        assertEq(lock.countryCode, UNCX_APP_COUNTRY);
        assertEq(POOL.balanceOf(OWNER), 0);
        assertEq(POOL.balanceOf(address(LOCKER)), locked);
        assertEq(ownerEth - OWNER.balance, ethFee);
    }

    // ---------------------------------------------------------------- 5. the empty pair before step three

    /// Anyone can send the empty pair 1 wei of WETH and sync it before the launch. Router02's
    /// addLiquidityETH then stops, whatever the minimums; KyzenLiquidity does not quote, and the
    /// launch goes through untaxed with the owner wallet's LP the same as on a clean pair.
    function test_5a_a_synced_weth_donation_to_the_empty_pair_does_not_stop_the_launch() public {
        _stepTwo();
        address griefer = makeAddr("griefer");
        vm.deal(griefer, 1 ether);
        vm.startPrank(griefer);
        IWETH(RH.WETH).deposit{value: 1}();
        assertTrue(IERC20(RH.WETH).transfer(PAIR, 1));
        POOL.sync();
        vm.stopPrank();
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, 0);
        assertEq(ethReserve, 1);

        vm.prank(OWNER);
        vm.expectRevert(bytes("UniswapV2Library: INSUFFICIENT_LIQUIDITY"));
        ROUTER.addLiquidityETH{value: LIQUIDITY_ETH}(address(TOKEN), LIQUIDITY_KYZN, 0, 0, OWNER, block.timestamp);

        (uint256 id, uint256 lp) = _stepThree(team);
        (kyznReserve, ethReserve) = _reserves();
        assertEq(kyznReserve, LIQUIDITY_KYZN);
        assertEq(ethReserve, LIQUIDITY_ETH + 1);
        assertEq(lp, Math.sqrt(LIQUIDITY_KYZN * LIQUIDITY_ETH) - MINIMUM_LIQUIDITY);
        assertEq(POOL.balanceOf(OWNER), lp);
        assertEq(SABLIER.getRecipient(id), team);
        assertEq(uint256(SABLIER.getDepositedAmount(id)), TEAM_STREAM);
        _assertNothingLeftBehind();
        _assertNoTax();
    }

    /// $KYZN out of the owner wallet before the launch lets its holder start the pool at its own
    /// price; the launch then refuses, and nothing moves.
    function test_5b_kyzn_given_out_lets_a_stranger_mint_first_and_the_launch_refuses() public {
        _stepTwo();
        address stranger = _strangerFundsThePair(1_000_000e18, 0.001 ether);
        vm.prank(stranger);
        uint256 strangerLp = POOL.mint(stranger);
        assertGt(strangerLp, 0);
        _assertNoTax();

        uint256 nextId = SABLIER_VIEWS.nextStreamId();
        uint256 ownerEth = OWNER.balance;
        _deployLiquidity(team);
        _approve();
        vm.prank(OWNER);
        vm.expectRevert(KyzenLiquidity.PoolAlreadyStarted.selector);
        liquidity.launch{value: LIQUIDITY_ETH}();
        assertFalse(liquidity.launched());
        assertEq(TOKEN.balanceOf(OWNER), SUPPLY - 1_000_000e18);
        assertEq(OWNER.balance, ownerEth);
        assertEq(SABLIER_VIEWS.nextStreamId(), nextId);
        assertEq(POOL.balanceOf(OWNER), 0);
    }

    /// Synced instead of minted, $KYZN given out leaves the pair with reserves and no liquidity
    /// tokens, which PoolAlreadyStarted does not see; the launch still stops, since it takes the
    /// whole supply from the owner wallet. So the 900,000,000 $KYZN can never go into a pool that
    /// already holds $KYZN, where they would pay the 10% sell tax.
    function test_5c_kyzn_given_out_and_synced_into_the_pair_also_stops_the_launch() public {
        _stepTwo();
        address stranger = _strangerFundsThePair(1_000_000e18, 0.001 ether);
        vm.prank(stranger);
        POOL.sync();
        assertEq(POOL.totalSupply(), 0);
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, 1_000_000e18);
        assertEq(ethReserve, 0.001 ether);

        uint256 nextId = SABLIER_VIEWS.nextStreamId();
        _deployLiquidity(team);
        _approve();
        vm.prank(OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, OWNER, SUPPLY - 1_000_000e18, SUPPLY)
        );
        liquidity.launch{value: LIQUIDITY_ETH}();
        assertFalse(liquidity.launched());
        assertEq(SABLIER_VIEWS.nextStreamId(), nextId);
        assertEq(TOKEN.balanceOf(OWNER), SUPPLY - 1_000_000e18);
        _assertNoTax();
    }

    // ---------------------------------------------------------------- the owner's transactions

    function _stepTwo() internal {
        _deployProtocol();
        _setProtocolAddresses();
        _acceptOwnership();
    }

    function _stepThree(address teamWallet) internal returns (uint256 id, uint256 lp) {
        _deployLiquidity(teamWallet);
        _approve();
        return _launch();
    }

    function _deployProtocol() internal {
        bytes memory initcode =
            abi.encodePacked(type(KyzenMainnetProtocol).creationCode, abi.encode(TOKEN, address(0), KEEPER, OPERATOR));
        address deployed;
        (deployed, ownerGas.protocolDeploy) = _deploy(initcode);
        protocol = KyzenMainnetProtocol(deployed);
        registry = protocol.registry();
        reserve = protocol.reserve();
        staking = protocol.staking();
        gateway = protocol.gateway();
    }

    function _setProtocolAddresses() internal {
        (address r, address s, address g) = (address(reserve), address(staking), address(gateway));
        vm.prank(OWNER);
        TOKEN.setProtocolAddresses(r, s, g);
        ownerGas.setProtocolAddresses = _callGas(abi.encodeCall(KyznToken.setProtocolAddresses, (r, s, g)));
    }

    function _acceptOwnership() internal {
        ownerGas.acceptRegistry = _accept(address(registry));
        ownerGas.acceptReserve = _accept(address(reserve));
        ownerGas.acceptStaking = _accept(address(staking));
        ownerGas.acceptGateway = _accept(address(gateway));
    }

    function _accept(address target) internal returns (uint256) {
        vm.prank(OWNER);
        Ownable2Step(target).acceptOwnership();
        return _callGas(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
    }

    function _deployLiquidity(address teamWallet) internal {
        bytes memory initcode =
            abi.encodePacked(type(KyzenMainnetLiquidity).creationCode, abi.encode(TOKEN, teamWallet));
        address deployed;
        (deployed, ownerGas.liquidityDeploy) = _deploy(initcode);
        liquidity = KyzenMainnetLiquidity(deployed);
    }

    function _approve() internal {
        address spender = address(liquidity);
        vm.prank(OWNER);
        TOKEN.approve(spender, SUPPLY);
        ownerGas.approve = _callGas(abi.encodeCall(IERC20.approve, (spender, SUPPLY)));
    }

    function _launch() internal returns (uint256 id, uint256 lp) {
        vm.prank(OWNER);
        liquidity.launch{value: LIQUIDITY_ETH}();
        ownerGas.launch = _callGas(abi.encodeCall(KyzenLiquidity.launch, ()));
        return (liquidity.streamId(), liquidity.lpTokens());
    }

    // ---------------------------------------------------------------- step three, checked

    /// Step three from the owner wallet and everything it leaves: the team stream on the real
    /// Sablier, the pool, the LP tokens, nothing left in the contract, no tax.
    function _launchAndCheck(address teamWallet) internal {
        uint256 expectedId = SABLIER_VIEWS.nextStreamId();
        uint256 expectedLp = Math.sqrt(LIQUIDITY_KYZN * LIQUIDITY_ETH) - MINIMUM_LIQUIDITY;
        uint256 ownerEth = OWNER.balance;
        uint256 sablierKyzn = TOKEN.balanceOf(address(SABLIER));
        uint256 launchedAt = TOKEN.launchedAt();
        uint256 start = block.timestamp;

        _deployLiquidity(teamWallet);
        assertEq(address(liquidity.token()), address(TOKEN));
        assertEq(liquidity.pair(), PAIR);
        assertEq(address(liquidity.sablier()), address(SABLIER));
        assertEq(liquidity.owner(), OWNER);
        assertEq(liquidity.teamWallet(), teamWallet);
        assertEq(liquidity.liquidityEth(), LIQUIDITY_ETH);
        assertFalse(liquidity.launched());
        _approve();
        assertEq(TOKEN.allowance(OWNER, address(liquidity)), SUPPLY);

        vm.expectEmit(true, false, false, true, address(liquidity));
        emit KyzenLiquidity.Launched(OWNER, expectedId, expectedLp);
        (uint256 id, uint256 lp) = _launch();
        assertTrue(liquidity.launched());
        assertEq(id, expectedId);
        assertEq(lp, expectedLp);

        // The team stream: 100,000,000 $KYZN, untaxed, from the owner wallet to the team wallet.
        _assertStream(id, teamWallet, start);
        assertEq(TOKEN.balanceOf(address(SABLIER)) - sablierKyzn, TEAM_STREAM);

        // The pool: 900,000,000 $KYZN and 2 ETH; every LP token but Uniswap's 1,000 to the owner.
        (uint256 kyznReserve, uint256 ethReserve) = _reserves();
        assertEq(kyznReserve, LIQUIDITY_KYZN);
        assertEq(ethReserve, LIQUIDITY_ETH);
        assertEq(TOKEN.balanceOf(PAIR), LIQUIDITY_KYZN);
        assertEq(IERC20(RH.WETH).balanceOf(PAIR), LIQUIDITY_ETH);
        assertEq(POOL.totalSupply(), expectedLp + MINIMUM_LIQUIDITY);
        assertEq(POOL.balanceOf(OWNER), expectedLp);
        assertEq(POOL.balanceOf(address(0)), MINIMUM_LIQUIDITY);

        // The owner wallet paid exactly the 2 ETH; nothing stayed anywhere it should not; no tax.
        assertEq(ownerEth - OWNER.balance, LIQUIDITY_ETH);
        _assertNothingLeftBehind();
        _assertNoTax();

        // Trading is open at the launch taxes, the max wallet on, the token as step one left it.
        assertEq(TOKEN.buyTaxBps(), 500);
        assertEq(TOKEN.sellTaxBps(), 1_000);
        assertTrue(TOKEN.maxWalletActive());
        assertEq(TOKEN.launchedAt(), launchedAt);
        assertEq(TOKEN.owner(), OWNER);

        // It runs once.
        vm.prank(OWNER);
        vm.expectRevert(KyzenLiquidity.AlreadyLaunched.selector);
        liquidity.launch{value: LIQUIDITY_ETH}();

        // Nothing before the cliff, linear over the 12 months after it, all of it at 18 months.
        vm.warp(Months.add(start, 6) - 1);
        assertEq(uint256(SABLIER.streamedAmountOf(id)), 0);
        vm.warp(Months.add(start, 12));
        assertApproxEqRel(uint256(SABLIER.streamedAmountOf(id)), 50_000_000e18, 0.01e18);
        vm.warp(Months.add(start, 18));
        assertEq(uint256(SABLIER.streamedAmountOf(id)), TEAM_STREAM);
    }

    /// SPEC 3.1's stream: from the launch, a 6-month cliff with nothing unlocked at the start or the
    /// cliff, then linear to 18 months; not cancelable, not transferable; the owner wallet its sender.
    function _assertStream(uint256 id, address teamWallet, uint256 start) internal view {
        assertEq(SABLIER.getRecipient(id), teamWallet);
        assertEq(SABLIER_VIEWS.ownerOf(id), teamWallet);
        assertEq(SABLIER.getSender(id), OWNER);
        assertEq(address(SABLIER_VIEWS.getUnderlyingToken(id)), address(TOKEN));
        assertEq(uint256(SABLIER.getDepositedAmount(id)), TEAM_STREAM);
        assertEq(uint256(SABLIER_VIEWS.getStartTime(id)), start);
        assertEq(uint256(SABLIER.getCliffTime(id)), Months.add(start, 6));
        assertEq(uint256(SABLIER.getEndTime(id)), Months.add(start, 18));
        (uint128 atStart, uint128 atCliff) = SABLIER_VIEWS.getUnlockAmounts(id);
        assertEq(atStart, 0);
        assertEq(atCliff, 0);
        assertFalse(SABLIER.isCancelable(id));
        assertFalse(SABLIER.isTransferable(id));
        assertEq(uint256(SABLIER.streamedAmountOf(id)), 0);
    }

    /// KyzenLiquidity keeps no $KYZN, LP, WETH or ETH and no allowance; the owner wallet keeps no $KYZN.
    function _assertNothingLeftBehind() internal view {
        address l = address(liquidity);
        assertEq(TOKEN.balanceOf(l), 0);
        assertEq(POOL.balanceOf(l), 0);
        assertEq(IERC20(RH.WETH).balanceOf(l), 0);
        assertEq(l.balance, 0);
        assertEq(TOKEN.allowance(OWNER, l), 0);
        assertEq(TOKEN.allowance(l, address(SABLIER)), 0);
        assertEq(TOKEN.balanceOf(OWNER), 0);
    }

    // ---------------------------------------------------------------- step two, checked

    /// The deployment's events: the four contracts, the keeper, the operator, SwapRouter02 queued
    /// for 24 hours from now, and each of the four offered to the owner wallet.
    function _assertDeployLogs(Vm.Log[] memory logs, uint256 queuedAt) internal view {
        bool deployed;
        bool queued;
        bool keeperSet;
        bool operatorSet;
        uint256 offers;
        for (uint256 i; i < logs.length; ++i) {
            Vm.Log memory l = logs[i];
            if (l.topics.length == 0) continue;
            bytes32 t0 = l.topics[0];
            if (l.emitter == address(protocol) && t0 == KyzenProtocol.Deployed.selector) {
                assertEq(l.topics[1], _topic(OWNER));
                assertEq(l.topics[2], _topic(address(TOKEN)));
                (address r0, address r1, address r2, address r3) =
                    abi.decode(l.data, (address, address, address, address));
                assertEq(r0, address(registry));
                assertEq(r1, address(reserve));
                assertEq(r2, address(staking));
                assertEq(r3, address(gateway));
                deployed = true;
            } else if (l.emitter == address(reserve) && t0 == Reserve.TargetQueued.selector) {
                assertEq(l.topics[1], _topic(RH.UNISWAP_V3_SWAP_ROUTER_02));
                (bool allowed, uint256 effectiveAt) = abi.decode(l.data, (bool, uint256));
                assertTrue(allowed);
                assertEq(effectiveAt, queuedAt + 24 hours);
                queued = true;
            } else if (l.emitter == address(reserve) && t0 == Reserve.KeeperSet.selector) {
                assertEq(l.topics[1], _topic(KEEPER));
                keeperSet = true;
            } else if (l.emitter == address(gateway) && t0 == GatewaySettlement.OperatorSet.selector) {
                assertEq(l.topics[1], _topic(OPERATOR));
                operatorSet = true;
            } else if (t0 == Ownable2Step.OwnershipTransferStarted.selector) {
                assertEq(l.topics[1], _topic(address(protocol)));
                assertEq(l.topics[2], _topic(OWNER));
                ++offers;
            }
        }
        assertTrue(deployed, "no Deployed event");
        assertTrue(queued, "swap target not queued");
        assertTrue(keeperSet, "keeper not set");
        assertTrue(operatorSet, "operator not set");
        assertEq(offers, 4, "not all four offered");
    }

    function _assertOwners(address owner_, address pending) internal view {
        Ownable2Step[4] memory four = [
            Ownable2Step(address(registry)),
            Ownable2Step(address(reserve)),
            Ownable2Step(address(staking)),
            Ownable2Step(address(gateway))
        ];
        for (uint256 i; i < four.length; ++i) {
            assertEq(four[i].owner(), owner_);
            assertEq(four[i].pendingOwner(), pending);
        }
    }

    /// Each contract built for the real token and Robinhood Chain's contracts, with the server's
    /// keeper and operator and the owner wallet as the host payout.
    function _assertProtocolSettings() internal view {
        assertEq(address(reserve.kyzn()), address(TOKEN));
        assertEq(address(reserve.weth()), RH.WETH);
        assertEq(reserve.ethUsdFeed(), RH.ETH_USD_FEED);
        assertEq(reserve.ethUsdDecimals(), IAggregatorV3(RH.ETH_USD_FEED).decimals());
        assertEq(address(reserve.registry()), address(registry));
        assertEq(reserve.keeper(), KEEPER);
        _assertAssets();

        assertEq(address(staking.kyzn()), address(TOKEN));
        assertEq(address(staking.router()), RH.UNISWAP_V2_ROUTER);
        assertEq(address(staking.weth()), RH.WETH);
        assertEq(address(staking.reserve()), address(reserve));
        assertEq(staking.equityAssetA(), RH.NVDA);
        assertEq(staking.equityAssetB(), RH.AMD);

        assertEq(address(gateway.kyzn()), address(TOKEN));
        assertEq(address(gateway.router()), RH.UNISWAP_V2_ROUTER);
        assertEq(gateway.hostPayout(), OWNER);
        assertEq(gateway.operator(), OPERATOR);
    }

    /// The seven stock tokens, in order, each with its feed and stage, listed from the start.
    function _assertAssets() internal view {
        RH.Asset[7] memory list = RH.assets();
        assertEq(reserve.assetCount(), list.length);
        for (uint256 i; i < list.length; ++i) {
            assertEq(reserve.assets(i), list[i].token);
            (address feed, uint8 feedDecimals, uint8 stage, uint64 lastTradeAt, bool listed) =
                reserve.assetInfo(list[i].token);
            assertEq(feed, list[i].feed);
            assertEq(feedDecimals, IAggregatorV3(list[i].feed).decimals());
            assertEq(stage, list[i].stage);
            assertEq(lastTradeAt, 0);
            assertTrue(listed);
        }
    }

    function _assertRecord(RecordMainnet.Record memory r) internal view {
        assertEq(r.token, address(TOKEN));
        assertEq(r.pair, PAIR);
        assertEq(r.registry, address(registry));
        assertEq(r.reserve, address(reserve));
        assertEq(r.staking, address(staking));
        assertEq(r.gateway, address(gateway));
        assertEq(r.owner, OWNER);
        assertEq(r.devWallet, OWNER);
        assertEq(r.hostPayout, OWNER);
        assertEq(r.keeper, KEEPER);
        assertEq(r.operator, OPERATOR);
    }

    // ---------------------------------------------------------------- trading after the launch

    /// A fresh wallet buys, then sells everything: 5% on the buy and 10% on the sell, each recorded
    /// for the Reserve and Staking at 2 and 1 points of the trade.
    function _roundTripPaysTheLaunchTaxes(address buyer) internal {
        uint256 gross = _amountOut(0.01 ether, RH.WETH);
        uint256 bought = _buy(buyer, 0.01 ether);
        uint256 buyTax = gross * 500 / 10_000;
        assertEq(bought, gross - buyTax, "the buy pays 5%");
        assertEq(TOKEN.balanceOf(address(TOKEN)), buyTax);
        assertEq(TOKEN.reserveTaxTokens(), buyTax * 200 / 500);
        assertEq(TOKEN.stakingTaxTokens(), buyTax * 100 / 500);

        // The tax held is under the swap threshold, so this sell meets no tax sale. Router02's
        // fee-on-transfer sell also pays out any WETH the router itself holds; from then on it holds
        // none, which the tax sale below counts on.
        assertLt(TOKEN.balanceOf(address(TOKEN)), TOKEN.swapThreshold());
        uint256 sellTax = bought * 1_000 / 10_000;
        uint256 routerWeth = IERC20(RH.WETH).balanceOf(address(ROUTER));
        uint256 expectedEth = _amountOut(bought - sellTax, address(TOKEN)) + routerWeth;
        assertEq(_sell(buyer, bought), expectedEth, "the sell pays 10%");
        assertEq(IERC20(RH.WETH).balanceOf(address(ROUTER)), 0);
        assertEq(TOKEN.balanceOf(buyer), 0);
        assertEq(TOKEN.balanceOf(address(TOKEN)), buyTax + sellTax);
        assertEq(TOKEN.reserveTaxTokens(), buyTax * 200 / 500 + sellTax * 200 / 1_000);
        assertEq(TOKEN.stakingTaxTokens(), buyTax * 100 / 500 + sellTax * 100 / 1_000);
        assertEq(address(reserve).balance, 0);
        assertEq(address(staking).balance, 0);
        assertEq(TOKEN.totalHeldEth(), 0);
    }

    /// A second round trip: the tax held is now above the threshold, so the sell first sells it
    /// through Router02 and pays the Reserve and Staking their ETH at once; development's ETH stays
    /// held in the token for the owner wallet. Returns development's ETH.
    function _secondRoundTripSellsTheTax(address seller) internal returns (uint256) {
        uint256 amount = _buy(seller, 0.01 ether);
        TaxSale memory t = _expectedSale(amount);
        assertGe(t.pending, TOKEN.swapThreshold());
        assertEq(t.sold, t.pending, "the whole tax held fits one sale");

        vm.recordLogs();
        uint256 sellerEth = _sell(seller, amount);
        _assertSaleLogs(t);
        assertGt(t.toReserve, 0);
        assertGt(t.toStaking, 0);
        assertGt(t.toDevelopment, 0);
        assertEq(address(reserve).balance, t.toReserve);
        assertEq(address(staking).balance, t.toStaking);
        assertEq(TOKEN.heldEth(OWNER), t.toDevelopment);
        assertEq(TOKEN.totalHeldEth(), t.toDevelopment);
        assertEq(address(TOKEN).balance, t.toDevelopment);

        // The sell's own 10% is taken and recorded after the sale, and the seller's $KYZN reaches the
        // pool at the reserves the sale left.
        uint256 sellTax = amount * 1_000 / 10_000;
        assertEq(TOKEN.balanceOf(address(TOKEN)), t.pending - t.sold + sellTax);
        assertEq(TOKEN.reserveTaxTokens(), t.recordedReserve - t.reserveSold + sellTax * 200 / 1_000);
        assertEq(TOKEN.stakingTaxTokens(), t.recordedStaking - t.stakingSold + sellTax * 100 / 1_000);
        assertEq(sellerEth, _getAmountOut(amount - sellTax, t.kyznReserve + t.sold, t.ethReserve - t.received));
        return t.toDevelopment;
    }

    /// Anyone may send the held ETH; the server's operator wallet does, to the development wallet,
    /// which is the owner wallet.
    function _theServerSendsTheHeldEthToTheOwnerWallet(uint256 held) internal {
        uint256 before = OWNER.balance;
        vm.prank(OPERATOR);
        TOKEN.sendHeldEth(OWNER);
        assertEq(OWNER.balance - before, held);
        assertEq(TOKEN.heldEth(OWNER), 0);
        assertEq(TOKEN.totalHeldEth(), 0);
        assertEq(address(TOKEN).balance, 0);
        vm.prank(OPERATOR);
        vm.expectRevert(KyznToken.NothingHeld.selector);
        TOKEN.sendHeldEth(OWNER);
    }

    /// While the max wallet is on, a buy that would take a wallet above 20,000,000 $KYZN reverts:
    /// the token's MaxWalletExceeded inside the pair's transfer, which Uniswap reports as its own
    /// TRANSFER_FAILED. The limit is what stops it: once the owner wallet removes it, the same buy
    /// goes through.
    function _aBuyAboveTheMaxWalletReverts(address whale) internal {
        assertTrue(TOKEN.maxWalletActive());
        uint256 held = _buy(whale, 0.04 ether);
        assertLe(held, TOKEN.MAX_WALLET());
        uint256 gross = _amountOut(0.02 ether, RH.WETH);
        uint256 net = gross - gross * 500 / 10_000;
        assertGt(held + net, TOKEN.MAX_WALLET());

        vm.deal(whale, 0.02 ether);
        vm.prank(whale);
        vm.expectRevert(bytes("UniswapV2: TRANSFER_FAILED"));
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.02 ether}(
            0, _path(RH.WETH, address(TOKEN)), whale, block.timestamp
        );
        assertEq(TOKEN.balanceOf(whale), held);

        vm.prank(OWNER);
        TOKEN.removeMaxWallet();
        assertEq(_buy(whale, 0.02 ether), net);
        assertGt(TOKEN.balanceOf(whale), TOKEN.MAX_WALLET());
    }

    // ---------------------------------------------------------------- gas

    /// The last call's gas as a transaction of its own. Isolated, it is the transaction's gas;
    /// otherwise the call's execution, plus the 21,000 and the calldata of a transaction.
    function _callGas(bytes memory data) internal returns (uint256) {
        uint256 used = vm.lastCallGas().gasTotalUsed;
        if (_isolated()) return used;
        return used + 21_000 + _calldataGas(data);
    }

    /// Deploys `initcode` from the owner wallet; returns the contract and the deployment's gas. The
    /// test pays its own CREATE (32,000 and 2 gas per word of init code); isolated, the rest is the
    /// deployment transaction's gas; otherwise it is the execution, and the transaction adds 21,000
    /// and the calldata.
    function _deploy(bytes memory initcode) internal returns (address deployed, uint256 gas_) {
        vm.prank(OWNER);
        uint256 before = gasleft();
        assembly ("memory-safe") {
            deployed := create(0, add(initcode, 0x20), mload(initcode))
        }
        uint256 spent = before - gasleft();
        assertTrue(deployed != address(0), "the deployment reverted");
        if (_isolated()) return (deployed, spent - 32_000 - 2 * ((initcode.length + 31) / 32));
        return (deployed, spent + 21_000 + _calldataGas(initcode));
    }

    /// Whether forge runs each call as a transaction of its own (forge test --isolate): an empty
    /// call then costs at least a transaction's 21,000.
    function _isolated() internal returns (bool) {
        probe.ping();
        return vm.lastCallGas().gasTotalUsed >= 21_000;
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 gas_) {
        for (uint256 i; i < data.length; ++i) {
            gas_ += data[i] == 0 ? 4 : 16;
        }
    }

    function _logOwnerGas() internal {
        OwnerGas memory g = ownerGas;
        emit log(_isolated()
                ? "Owner transactions, gas as each receipt shows it, before Robinhood Chain's data fee:"
                : "Owner transactions, estimated gas (forge test --isolate for each receipt's gas):");
        emit log_named_uint("  1 deploy KyzenMainnetProtocol      ", g.protocolDeploy);
        emit log_named_uint("  2 token.setProtocolAddresses        ", g.setProtocolAddresses);
        emit log_named_uint("  3 registry.acceptOwnership          ", g.acceptRegistry);
        emit log_named_uint("  4 reserve.acceptOwnership           ", g.acceptReserve);
        emit log_named_uint("  5 staking.acceptOwnership           ", g.acceptStaking);
        emit log_named_uint("  6 gateway.acceptOwnership           ", g.acceptGateway);
        emit log_named_uint("  7 deploy KyzenMainnetLiquidity      ", g.liquidityDeploy);
        emit log_named_uint("  8 token.approve(liquidity, supply)  ", g.approve);
        emit log_named_uint("  9 liquidity.launch{value: 2 ETH}    ", g.launch);
        uint256 total = g.protocolDeploy + g.setProtocolAddresses + g.acceptRegistry + g.acceptReserve + g.acceptStaking
            + g.acceptGateway + g.liquidityDeploy + g.approve + g.launch;
        emit log_named_uint("  total                               ", total);
        emit log_named_uint("  base fee at the fork block (wei)    ", block.basefee);
        emit log_named_decimal_uint("  total at that base fee (ETH)        ", total * block.basefee, 18);
    }

    // ---------------------------------------------------------------- helpers

    /// Sends the stranger $KYZN from the owner wallet (a wallet-to-wallet transfer, untaxed); the
    /// stranger sends it and some WETH into the empty pair.
    function _strangerFundsThePair(uint256 kyzn, uint256 eth) internal returns (address stranger) {
        stranger = makeAddr("stranger");
        vm.prank(OWNER);
        assertTrue(TOKEN.transfer(stranger, kyzn));
        vm.deal(stranger, eth);
        vm.startPrank(stranger);
        assertTrue(TOKEN.transfer(PAIR, kyzn));
        IWETH(RH.WETH).deposit{value: eth}();
        assertTrue(IERC20(RH.WETH).transfer(PAIR, eth));
        vm.stopPrank();
    }

    /// No tax taken, none recorded, no ETH held.
    function _assertNoTax() internal view {
        assertEq(TOKEN.balanceOf(address(TOKEN)), 0, "tax taken");
        assertEq(TOKEN.reserveTaxTokens(), 0, "Reserve share recorded");
        assertEq(TOKEN.stakingTaxTokens(), 0, "Staking share recorded");
        assertEq(TOKEN.totalHeldEth(), 0, "ETH held");
    }

    function _topic(address account) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(account)));
    }

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _reserves() internal view returns (uint256 kyzn, uint256 eth) {
        (uint112 r0, uint112 r1,) = POOL.getReserves();
        (kyzn, eth) = POOL.token0() == address(TOKEN) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// Uniswap v2's output, 0.3% fee.
    function _getAmountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) internal pure returns (uint256) {
        uint256 withFee = amountIn * 997;
        return withFee * reserveOut / (reserveIn * 1000 + withFee);
    }

    /// The output for `amountIn` of `tokenIn` at the pool's current reserves.
    function _amountOut(uint256 amountIn, address tokenIn) internal view returns (uint256) {
        (uint256 kyzn, uint256 eth) = _reserves();
        return tokenIn == address(TOKEN) ? _getAmountOut(amountIn, kyzn, eth) : _getAmountOut(amountIn, eth, kyzn);
    }

    function _buy(address who, uint256 ethIn) internal returns (uint256 got) {
        vm.deal(who, who.balance + ethIn);
        uint256 before = TOKEN.balanceOf(who);
        vm.prank(who);
        ROUTER.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            0, _path(RH.WETH, address(TOKEN)), who, block.timestamp
        );
        got = TOKEN.balanceOf(who) - before;
    }

    function _sell(address who, uint256 amount) internal returns (uint256 eth) {
        uint256 before = who.balance;
        vm.startPrank(who);
        TOKEN.approve(address(ROUTER), amount);
        ROUTER.swapExactTokensForETHSupportingFeeOnTransferTokens(
            amount, 0, _path(address(TOKEN), RH.WETH), who, block.timestamp
        );
        vm.stopPrank();
        eth = who.balance - before;
    }

    /// The tax sale a sell of `sellAmount` triggers now, as KyznToken._sellTaxIfDue and _distribute
    /// compute it: at most the tax held, the sell and 0.25% of the pool's $KYZN, sold at the current
    /// reserves, its ETH split by the recorded Reserve and Staking shares of what is sold.
    function _expectedSale(uint256 sellAmount) internal view returns (TaxSale memory t) {
        (t.kyznReserve, t.ethReserve) = _reserves();
        t.pending = TOKEN.balanceOf(address(TOKEN));
        t.recordedReserve = TOKEN.reserveTaxTokens();
        t.recordedStaking = TOKEN.stakingTaxTokens();
        t.sold = Math.min(Math.min(t.pending, sellAmount), TOKEN.balanceOf(PAIR) * TOKEN.SWAP_POOL_BPS() / TOKEN.BPS());
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
            if (logs[i].emitter != address(TOKEN) || logs[i].topics.length == 0) continue;
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
