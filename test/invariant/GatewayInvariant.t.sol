// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {GatewaySettlement} from "../../src/GatewaySettlement.sol";
import {Fixture} from "../utils/Fixture.sol";

/// Random settlement windows: new $KYZN inference revenue arrives (a plain wallet-to-wallet
/// transfer, untaxed), then the operator settles the gateway's whole current balance, burning at
/// least the 1/11 margin (SPEC 3.6). A second action tries a split one wei below the margin,
/// which the contract must refuse; the invariants fail if it ever accepts one.
contract GatewayHandler is Test {
    KyznToken internal token;
    GatewaySettlement internal gateway;
    address internal operator;

    uint256 public ghostSold;
    uint256 public ghostBurned;
    uint256 public ghostToHost;
    uint256 public settlements;
    uint256 public belowMarginRejected;
    bool public belowMarginAccepted;

    constructor(KyznToken token_, GatewaySettlement gateway_, address operator_) {
        token = token_;
        gateway = gateway_;
        operator = operator_;
    }

    function settle(uint256 payment, uint256 burnBps) external {
        uint256 have = token.balanceOf(address(this));
        payment = bound(payment, 0, have);
        if (payment != 0) token.transfer(address(gateway), payment);

        uint256 balance = token.balanceOf(address(gateway));
        if (balance == 0) return;

        // ceil(balance / 11): the smallest burnAmount for which sellAmount = balance - burnAmount
        // still satisfies burnAmount * 10 >= sellAmount.
        uint256 minBurn = (balance + 10) / 11;
        burnBps = bound(burnBps, 0, 10_000);
        uint256 burnAmount = balance * burnBps / 10_000;
        if (burnAmount < minBurn) burnAmount = minBurn;
        if (burnAmount > balance) burnAmount = balance;
        uint256 sellAmount = balance - burnAmount;

        vm.prank(operator);
        uint256 ethToHost = gateway.settle(sellAmount, burnAmount, 0);
        ghostSold += sellAmount;
        ghostBurned += burnAmount;
        ghostToHost += ethToHost;
        ++settlements;
    }

    /// Tries to settle the whole balance burning one wei less than ceil(balance / 11).
    function settleBelowMargin(uint256 payment) external {
        uint256 have = token.balanceOf(address(this));
        payment = bound(payment, 0, have);
        if (payment != 0) token.transfer(address(gateway), payment);

        uint256 balance = token.balanceOf(address(gateway));
        if (balance == 0) return;
        uint256 burnAmount = (balance + 10) / 11 - 1;
        uint256 sellAmount = balance - burnAmount;

        vm.prank(operator);
        try gateway.settle(sellAmount, burnAmount, 0) returns (uint256 ethToHost) {
            belowMarginAccepted = true;
            ghostSold += sellAmount;
            ghostBurned += burnAmount;
            ghostToHost += ethToHost;
            ++settlements;
        } catch {
            ++belowMarginRejected;
        }
    }
}

/// SPEC Step 4 Gateway invariants (review items 6, 10): the lifetime totals equal the sums the
/// handler recorded from each settle() call (which is exactly what each Settled event carries),
/// and the 1/11 burn margin holds across every window combined, not only per call.
contract GatewayInvariantTest is Fixture {
    GatewayHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new GatewayHandler(token, gateway, operator);
        token.transfer(address(handler), 50_000_000e18);
        _launch();
        token.removeMaxWallet();
        targetContract(address(handler));
    }

    function invariant_totals_match_the_settled_events_the_handler_recorded() public view {
        assertEq(gateway.totalSold(), handler.ghostSold());
        assertEq(gateway.totalBurned(), handler.ghostBurned());
        assertEq(gateway.totalToHost(), handler.ghostToHost());
    }

    function invariant_burn_margin_holds_across_every_window() public view {
        assertGe(gateway.totalBurned() * 11, gateway.totalSold() + gateway.totalBurned());
    }

    function invariant_no_split_below_the_margin_is_ever_accepted() public view {
        assertFalse(handler.belowMarginAccepted());
    }

    /// The below-margin action is reachable and refused (the fuzzer's outer call never reverts).
    function test_handler_attempts_and_the_contract_refuses_a_split_below_the_margin() public {
        handler.settleBelowMargin(1_000e18);
        assertEq(handler.belowMarginRejected(), 1);
        assertFalse(handler.belowMarginAccepted());
    }
}
