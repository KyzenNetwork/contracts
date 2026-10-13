// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {Fixture} from "../utils/Fixture.sol";
import {MockUniswapV2Router} from "../mocks/MockUniswapV2.sol";
import {PayableProtocolStub} from "../mocks/ProtocolStub.sol";

/// Random buys, sells, transfers, burns and tax cuts by three traders, from the launch taxes
/// (5% on buys, 10% on sells) down, while the owner changes the swap threshold, the development
/// wallet and the protocol addresses (between two valid sets, the second of which may refuse ETH
/// or burn the gas sent with it) and anyone sends held ETH. Each trade's recorded Reserve and
/// Staking shares, and each swap-back's split of them, are recomputed here and compared exactly.
contract TokenHandler is Test {
    /// The ETH recipients the handler can produce: three development wallets and two Reserve and
    /// Staking pairs.
    uint256 public constant RECIPIENTS = 7;
    /// Gas for each sendHeldEth call, so a recipient that burns all it gets ends in reasonable time.
    uint256 internal constant SEND_HELD_GAS = 1_000_000;

    KyznToken internal token;
    MockUniswapV2Router internal router;
    address internal weth;
    address internal owner;
    address[3] internal actors;
    address[3] internal devWallets;
    /// Two valid protocol-address sets: (Reserve, Staking, Gateway).
    address[3][2] internal protocolSets;
    PayableProtocolStub internal stubReserve;
    PayableProtocolStub internal stubStaking;
    uint256 public currentSet;

    uint256 public ghostTaxTaken; // tax the handler expects the token to take
    uint256 public ghostTaxSold; // tokens the tax swaps sold (TaxSwapped events)
    uint256 public ghostTaxEth; // ETH the tax swaps received (TaxSwapped events)
    uint256 public ghostToReserve; // shares sent or held (TaxDistributed events)
    uint256 public ghostToStaking;
    uint256 public ghostToDevelopment;
    /// ETH each recipient was allotted by the tax sales, sent or held: to the Reserve, Staking and
    /// development wallet in place at each sale.
    mapping(address => uint256) public ghostShareOf;
    uint256 public swaps;
    uint256 public ghostReserveRecorded; // 2 points of every tax, at its trade's level
    uint256 public ghostStakingRecorded; // 1 point of every tax
    uint256 public ghostReserveSold; // recorded shares the swap-backs sold
    uint256 public ghostStakingSold;
    uint256 public cuts;
    bool public splitWrong; // a swap-back that did not pay exactly the recorded shares sold
    uint256 public lastSupply;
    bool public supplyRose;
    /// A sell of an amount the seller holds reverted (it never should).
    bool public sellReverted;
    bytes public sellRevertReason;
    uint256 public sends; // sendHeldEth calls that paid
    uint256 public refusedSends; // sendHeldEth calls a refusing recipient reverted
    /// A sendHeldEth call paid the wrong amount, or failed for a recipient that accepts ETH.
    bool public sendWrong;
    uint256 public switches;

    constructor(
        KyznToken token_,
        MockUniswapV2Router router_,
        address owner_,
        address[3] memory devWallets_,
        address[3][2] memory protocolSets_
    ) {
        token = token_;
        router = router_;
        weth = router_.WETH();
        owner = owner_;
        actors = [makeAddr("trader1"), makeAddr("trader2"), makeAddr("trader3")];
        devWallets = devWallets_;
        protocolSets = protocolSets_;
        stubReserve = PayableProtocolStub(payable(protocolSets_[1][0]));
        stubStaking = PayableProtocolStub(payable(protocolSets_[1][1]));
        lastSupply = token_.totalSupply();
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    /// The development wallets, then the first set's Reserve and Staking, then the second set's.
    function recipient(uint256 i) public view returns (address) {
        if (i < 3) return devWallets[i];
        if (i < 5) return protocolSets[0][i - 3];
        return protocolSets[1][i - 5];
    }

    // ---------------------------------------------------------------- trades

    function buy(uint256 who, uint256 ethIn) external {
        address a = actors[who % 3];
        ethIn = bound(ethIn, 1e12, 0.05 ether);
        vm.deal(a, ethIn);
        address[] memory path = new address[](2);
        path[0] = weth;
        path[1] = address(token);
        uint256 level = token.buyTaxBps();
        uint256 tax = ethIn * router.TOKENS_PER_ETH() * level / 10_000;
        Before memory b = _before();
        vm.recordLogs();
        vm.prank(a);
        try router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(0, path, a, block.timestamp) {
            _taxed(tax, level);
        } catch {}
        _afterAction(b);
    }

    function sell(uint256 who, uint256 amount) external {
        address a = actors[who % 3];
        uint256 balance = token.balanceOf(a);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        address[] memory path = new address[](2);
        path[0] = address(token);
        path[1] = weth;
        uint256 level = token.sellTaxBps();
        uint256 tax = amount * level / 10_000;
        vm.prank(a);
        token.approve(address(router), amount);
        Before memory b = _before();
        vm.recordLogs();
        vm.prank(a);
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, path, a, block.timestamp) {
            _taxed(tax, level);
        } catch (bytes memory reason) {
            sellReverted = true;
            sellRevertReason = reason;
        }
        _afterAction(b);
    }

    function transfer(uint256 from, uint256 to, uint256 amount) external {
        address a = actors[from % 3];
        uint256 balance = token.balanceOf(a);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        Before memory b = _before();
        vm.recordLogs();
        vm.prank(a);
        token.transfer(actors[to % 3], amount);
        _afterAction(b);
    }

    function burn(uint256 who, uint256 amount) external {
        address a = actors[who % 3];
        uint256 balance = token.balanceOf(a);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        Before memory b = _before();
        vm.recordLogs();
        vm.prank(a);
        token.burn(amount);
        _afterAction(b);
    }

    // ---------------------------------------------------------------- held ETH

    /// Anyone sends a recipient the ETH held for it. It pays exactly that, or, for a recipient
    /// that refuses ETH or burns the gas, reverts and keeps it held.
    function sendHeldEth(uint256 which) external {
        address r = recipient(which % RECIPIENTS);
        uint256 held = token.heldEth(r);
        if (held == 0) return;
        uint256 balanceBefore = r.balance;
        try token.sendHeldEth{gas: SEND_HELD_GAS}(r) {
            ++sends;
            if (r.balance != balanceBefore + held || token.heldEth(r) != 0) sendWrong = true;
        } catch {
            ++refusedSends;
            if (_acceptsEth(r) || token.heldEth(r) != held || r.balance != balanceBefore) sendWrong = true;
        }
    }

    /// The second set's Reserve and Staking take, refuse or burn the gas of the ETH sent to them.
    function setStubModes(uint256 reserveMode, uint256 stakingMode) external {
        stubReserve.setMode(PayableProtocolStub.Mode(reserveMode % 3));
        stubStaking.setMode(PayableProtocolStub.Mode(stakingMode % 3));
    }

    // ---------------------------------------------------------------- owner

    /// Lowers the buy and the sell tax by up to 100 bps each, never below the 4% floor.
    function lowerTax(uint256 buyCut, uint256 sellCut) external {
        uint256 floor = token.MIN_TAX_BPS();
        uint256 buyBps = token.buyTaxBps();
        uint256 sellBps = token.sellTaxBps();
        uint256 newBuy = buyBps - bound(buyCut, 0, _min(100, buyBps - floor));
        uint256 newSell = sellBps - bound(sellCut, 0, _min(100, sellBps - floor));
        if (newBuy == buyBps && newSell == sellBps) return;
        Before memory b = _before();
        vm.recordLogs();
        vm.prank(owner);
        token.lowerTax(newBuy, newSell);
        ++cuts;
        _afterAction(b);
    }

    function setSwapThreshold(uint256 amount) external {
        amount = bound(amount, token.MIN_SWAP_THRESHOLD(), token.MAX_SWAP_THRESHOLD());
        vm.prank(owner);
        token.setSwapThreshold(amount);
    }

    function setDevWallet(uint256 which) external {
        vm.prank(owner);
        token.setDevWallet(devWallets[which % 3]);
    }

    /// Replaces the Reserve, Staking and Gateway with the other valid set.
    function switchProtocolAddresses() external {
        currentSet = 1 - currentSet;
        address[3] memory set = protocolSets[currentSet];
        vm.prank(owner);
        token.setProtocolAddresses(set[0], set[1], set[2]);
        ++switches;
    }

    // ---------------------------------------------------------------- bookkeeping

    /// The tax balance and the recorded shares before an action.
    struct Before {
        uint256 pending;
        uint256 reserveTokens;
        uint256 stakingTokens;
        uint256 addedReserve;
        uint256 addedStaking;
    }

    Before internal _pendingAdd;

    function _before() internal returns (Before memory b) {
        b.pending = token.balanceOf(address(token));
        b.reserveTokens = token.reserveTaxTokens();
        b.stakingTokens = token.stakingTaxTokens();
        delete _pendingAdd;
    }

    /// A trade's tax went through: its shares, at its own level.
    function _taxed(uint256 tax, uint256 level) internal {
        ghostTaxTaken += tax;
        _pendingAdd.addedReserve = tax * 200 / level;
        _pendingAdd.addedStaking = tax * 100 / level;
        ghostReserveRecorded += _pendingAdd.addedReserve;
        ghostStakingRecorded += _pendingAdd.addedStaking;
    }

    function _afterAction(Before memory b) internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 sold;
        uint256 eth;
        uint256 reserveSold;
        uint256 stakingSold;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(token)) continue;
            if (logs[i].topics[0] == KyznToken.TaxSwapped.selector) {
                (sold, eth) = abi.decode(logs[i].data, (uint256, uint256));
                ghostTaxSold += sold;
                ghostTaxEth += eth;
                ++swaps;
                // The swap-back runs before the trade's own tax: it sells from the balance before.
                reserveSold = b.reserveTokens * sold / b.pending;
                stakingSold = b.stakingTokens * sold / b.pending;
                ghostReserveSold += reserveSold;
                ghostStakingSold += stakingSold;
            } else if (logs[i].topics[0] == KyznToken.TaxDistributed.selector) {
                (uint256 r, uint256 s, uint256 d) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                if (r != eth * reserveSold / sold || s != eth * stakingSold / sold || r + s + d != eth) {
                    splitWrong = true;
                }
                ghostToReserve += r;
                ghostToStaking += s;
                ghostToDevelopment += d;
                // No action that trades changes these: they are the recipients of this sale.
                ghostShareOf[token.reserve()] += r;
                ghostShareOf[token.staking()] += s;
                ghostShareOf[token.devWallet()] += d;
            }
        }
        if (token.reserveTaxTokens() != b.reserveTokens - reserveSold + _pendingAdd.addedReserve) splitWrong = true;
        if (token.stakingTaxTokens() != b.stakingTokens - stakingSold + _pendingAdd.addedStaking) splitWrong = true;
        delete _pendingAdd;
        uint256 supply = token.totalSupply();
        if (supply > lastSupply) supplyRose = true;
        lastSupply = supply;
    }

    /// Whether `r` takes ETH from the token: all but the second set's stubs when set to refuse
    /// or burn the gas.
    function _acceptsEth(address r) internal view returns (bool) {
        if (r == address(stubReserve)) return stubReserve.mode() == PayableProtocolStub.Mode.Accept;
        if (r == address(stubStaking)) return stubStaking.mode() == PayableProtocolStub.Mode.Accept;
        return true;
    }

    function _min(uint256 a, uint256 b) internal pure returns (uint256) {
        return a < b ? a : b;
    }
}

/// SPEC Step 4 token invariants: supply never increases; every token of tax is either still held
/// or was sold; every wei of tax ETH reached the recipient in place at its sale or is held for it,
/// and the token's ETH is exactly what it holds; the Reserve's and Staking's shares are recorded
/// at each trade's own level and paid as they sell; a holder can always sell.
contract TokenInvariantTest is Fixture {
    TokenHandler internal handler;

    function setUp() public override {
        super.setUp();
        (PayableProtocolStub r2, PayableProtocolStub s2, address g2) =
            _payableStubs(token, PayableProtocolStub.Mode.Accept, PayableProtocolStub.Mode.Accept);
        address[3][2] memory sets =
            [[address(reserve), address(staking), address(gateway)], [address(r2), address(s2), g2]];
        handler = new TokenHandler(token, router, address(this), [dev, makeAddr("dev2"), makeAddr("dev3")], sets);
        token.setSwapThreshold(100_000e18); // swaps come sooner, so runs exercise them
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actor(i), 5_000_000e18);
        }
        // At the launch taxes; the handler lowers them.
        token.removeMaxWallet();
        targetContract(address(handler));
    }

    /// The handler reaches every path the invariants depend on: a sale, a switch of protocol
    /// addresses, sends refused by a refusing and a gas-burning recipient, and sends that pay.
    function test_handler_reaches_sales_switches_refused_and_paid_sends() public {
        handler.buy(0, 0.05 ether); // 750,000 tax at 5%, above the threshold
        handler.switchProtocolAddresses();
        handler.setStubModes(uint256(PayableProtocolStub.Mode.Refuse), uint256(PayableProtocolStub.Mode.BurnGas));
        handler.sell(0, 1_000_000e18);
        assertEq(handler.swaps(), 1);
        assertEq(handler.switches(), 1);
        address stubReserve = handler.recipient(5);
        address stubStaking = handler.recipient(6);
        assertEq(token.reserve(), stubReserve);
        assertGt(token.heldEth(stubReserve), 0);
        assertGt(token.heldEth(stubStaking), 0);

        handler.sendHeldEth(5);
        handler.sendHeldEth(6);
        assertEq(handler.refusedSends(), 2);
        assertEq(handler.sends(), 0);
        handler.setStubModes(uint256(PayableProtocolStub.Mode.Accept), uint256(PayableProtocolStub.Mode.Accept));
        handler.sendHeldEth(5);
        handler.sendHeldEth(6);
        handler.sendHeldEth(0); // dev
        assertEq(handler.sends(), 3);
        assertGt(stubReserve.balance, 0);
        assertGt(stubStaking.balance, 0);
        assertGt(dev.balance, 0);

        assertFalse(handler.sendWrong());
        assertFalse(handler.sellReverted());
        invariant_tax_eth_is_conserved();
        invariant_every_share_reached_its_recipient();
        invariant_the_token_s_eth_is_exactly_the_eth_held();
        invariant_shares_are_recorded_and_paid_exactly();
    }

    function invariant_supply_never_increases() public view {
        assertLe(token.totalSupply(), token.INITIAL_SUPPLY());
        assertFalse(handler.supplyRose());
    }

    function invariant_tax_tokens_are_conserved() public view {
        assertEq(handler.ghostTaxTaken(), handler.ghostTaxSold() + token.balanceOf(address(token)));
    }

    function invariant_tax_eth_is_conserved() public view {
        uint256 reached = token.totalHeldEth();
        for (uint256 i; i < handler.RECIPIENTS(); ++i) {
            reached += handler.recipient(i).balance;
        }
        assertEq(handler.ghostTaxEth(), reached);
        assertEq(
            handler.ghostTaxEth(), handler.ghostToReserve() + handler.ghostToStaking() + handler.ghostToDevelopment()
        );
    }

    function invariant_shares_are_recorded_and_paid_exactly() public view {
        assertFalse(handler.splitWrong());
        assertEq(token.reserveTaxTokens(), handler.ghostReserveRecorded() - handler.ghostReserveSold());
        assertEq(token.stakingTaxTokens(), handler.ghostStakingRecorded() - handler.ghostStakingSold());
        // The recorded shares are part of the tax balance, never more than it.
        assertLe(uint256(token.reserveTaxTokens()) + token.stakingTaxTokens(), token.balanceOf(address(token)));
    }

    function invariant_taxes_stay_within_their_bounds() public view {
        assertLe(token.buyTaxBps(), token.INITIAL_BUY_TAX_BPS());
        assertLe(token.sellTaxBps(), token.INITIAL_SELL_TAX_BPS());
        assertGe(token.buyTaxBps(), token.MIN_TAX_BPS());
        assertGe(token.sellTaxBps(), token.MIN_TAX_BPS());
    }

    /// Each recipient's ETH, received or still held for it, is exactly its shares of the sales made
    /// while it was in place.
    function invariant_every_share_reached_its_recipient() public view {
        for (uint256 i; i < handler.RECIPIENTS(); ++i) {
            address r = handler.recipient(i);
            assertEq(r.balance + token.heldEth(r), handler.ghostShareOf(r));
        }
    }

    /// The token's ETH is exactly what it holds for recipients, and that is the sum of their
    /// held amounts.
    function invariant_the_token_s_eth_is_exactly_the_eth_held() public view {
        assertEq(address(token).balance, token.totalHeldEth());
        uint256 held;
        for (uint256 i; i < handler.RECIPIENTS(); ++i) {
            held += token.heldEth(handler.recipient(i));
        }
        assertEq(held, token.totalHeldEth());
    }

    function invariant_a_sell_of_tokens_held_never_reverts() public view {
        assertFalse(handler.sellReverted());
        assertEq(handler.sellRevertReason().length, 0);
    }

    function invariant_held_eth_sends_pay_exactly_or_fail_only_for_a_refusing_recipient() public view {
        assertFalse(handler.sendWrong());
    }
}
