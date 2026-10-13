// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {GatewaySettlement} from "../src/GatewaySettlement.sol";
import {IKyzn} from "../src/interfaces/IKyzn.sol";
import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {Fixture} from "./utils/Fixture.sol";

/// A host payout address that is also the operator and settles again when paid.
contract ReentrantHost {
    GatewaySettlement public gateway;

    function setGateway(GatewaySettlement gateway_) external {
        gateway = gateway_;
    }

    function settle(uint256 sellAmount, uint256 burnAmount) external {
        gateway.settle(sellAmount, burnAmount, 0);
    }

    receive() external payable {
        gateway.settle(0, 1, 0);
    }
}

/// Gateway settlement: sell for the host bill, burn at least the 1/11 margin (SPEC 3.6).
contract GatewaySettlementTest is Fixture {
    function setUp() public override {
        super.setUp();
        _launch();
        token.removeMaxWallet();
        token.transfer(address(gateway), 11_000_000e18); // inference payments received
    }

    /// The owner sets the wallet the host bill's ETH goes to; the burn floor is unchanged.
    function test_the_owner_sets_the_host_payout() public {
        address newHost = makeAddr("newHost");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gateway.setHostPayout(newHost);
        vm.expectRevert(GatewaySettlement.ZeroAddress.selector);
        gateway.setHostPayout(address(0));
        vm.expectEmit(address(gateway));
        emit GatewaySettlement.HostPayoutSet(newHost);
        gateway.setHostPayout(newHost);
        assertEq(gateway.hostPayout(), newHost);

        token.transfer(address(gateway), 1_100_000e18);
        vm.prank(operator);
        uint256 eth = gateway.settle(1_000_000e18, 100_000e18, 0);
        assertGt(eth, 0);
        assertEq(newHost.balance, eth);
        assertEq(host.balance, 0);
    }

    function test_settle_burns_the_margin_and_pays_the_host() public {
        uint256 supply = token.totalSupply();
        uint256 expectedEth = 10_000_000e18 / router.TOKENS_PER_ETH();
        vm.expectEmit(address(gateway));
        emit GatewaySettlement.Settled(10_000_000e18, 1_000_000e18, expectedEth);
        vm.prank(operator);
        uint256 eth = gateway.settle(10_000_000e18, 1_000_000e18, 0);
        assertEq(eth, expectedEth);
        assertEq(host.balance, expectedEth);
        assertEq(token.totalSupply(), supply - 1_000_000e18);
        assertEq(token.balanceOf(address(gateway)), 0);
        assertEq(token.balanceOf(address(token)), 0); // the sale was untaxed
    }

    function test_burn_floor_is_one_eleventh() public {
        vm.startPrank(operator);
        vm.expectRevert(GatewaySettlement.BurnBelowMargin.selector);
        gateway.settle(10_000_000e18 + 1, 1_000_000e18, 0);
        gateway.settle(10_000_000e18, 1_000_000e18, 0); // exactly 1/11 burned
        vm.stopPrank();
    }

    function test_operator_can_burn_more() public {
        uint256 supply = token.totalSupply();
        vm.prank(operator);
        gateway.settle(5_000_000e18, 6_000_000e18, 0);
        assertEq(token.totalSupply(), supply - 6_000_000e18);
    }

    function test_burn_only_settlement() public {
        vm.prank(operator);
        assertEq(gateway.settle(0, 1_000_000e18, 0), 0);
        assertEq(host.balance, 0);
    }

    function test_nothing_to_settle_reverts() public {
        vm.prank(operator);
        vm.expectRevert(GatewaySettlement.NothingToSettle.selector);
        gateway.settle(0, 0, 0);
    }

    function test_only_the_operator_settles() public {
        vm.prank(alice);
        vm.expectRevert(GatewaySettlement.NotOperator.selector);
        gateway.settle(10_000_000e18, 1_000_000e18, 0);
    }

    function test_minimum_eth_out_applies() public {
        uint256 tooMuch = 10_000_000e18 / router.TOKENS_PER_ETH() + 1;
        vm.prank(operator);
        vm.expectRevert(bytes("MockRouter: slippage"));
        gateway.settle(10_000_000e18, 1_000_000e18, tooMuch);
    }

    function test_setOperator_is_owner_only() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        gateway.setOperator(alice);
        vm.expectEmit(address(gateway));
        emit GatewaySettlement.OperatorSet(bob);
        gateway.setOperator(bob);
        assertEq(gateway.operator(), bob);
    }

    /// The constructor sets the first host payout and announces it as setHostPayout does; the
    /// owner can change it later (test_the_owner_sets_the_host_payout).
    function test_the_constructor_sets_the_first_host_payout() public {
        assertEq(gateway.hostPayout(), host);
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(predicted);
        emit GatewaySettlement.HostPayoutSet(bob);
        GatewaySettlement fresh = new GatewaySettlement(IKyzn(address(token)), IUniswapV2Router02(address(router)), bob);
        assertEq(address(fresh), predicted);
        assertEq(fresh.hostPayout(), bob);
        assertEq(fresh.operator(), address(0));
    }

    function test_settlement_never_triggers_the_tax_swap() public {
        _buy(alice, 0.05 ether); // 600,000 tax pending, above the threshold
        vm.prank(operator);
        gateway.settle(10_000_000e18, 1_000_000e18, 0);
        assertEq(token.balanceOf(address(token)), 600_000e18);
    }

    function test_constructor_rejects_zero_addresses() public {
        vm.expectRevert(GatewaySettlement.ZeroAddress.selector);
        new GatewaySettlement(IKyzn(address(0)), IUniswapV2Router02(address(router)), host);
        vm.expectRevert(GatewaySettlement.ZeroAddress.selector);
        new GatewaySettlement(IKyzn(address(token)), IUniswapV2Router02(address(0)), host);
        vm.expectRevert(GatewaySettlement.ZeroAddress.selector);
        new GatewaySettlement(IKyzn(address(token)), IUniswapV2Router02(address(router)), address(0));
    }

    function test_settle_records_lifetime_totals() public {
        uint256 expectedEth = 10_000_000e18 / router.TOKENS_PER_ETH();
        vm.prank(operator);
        gateway.settle(10_000_000e18, 1_000_000e18, 0);
        assertEq(gateway.totalSold(), 10_000_000e18);
        assertEq(gateway.totalBurned(), 1_000_000e18);
        assertEq(gateway.totalToHost(), expectedEth);
    }

    function test_settle_accumulates_lifetime_totals_across_multiple_windows() public {
        vm.prank(operator);
        gateway.settle(10_000_000e18, 1_000_000e18, 0); // window 1 spends the whole 11,000,000 balance
        token.transfer(address(gateway), 5_500_000e18); // window 2 revenue
        vm.prank(operator);
        gateway.settle(5_000_000e18, 500_000e18, 0);

        uint256 expectedEth = 10_000_000e18 / router.TOKENS_PER_ETH() + 5_000_000e18 / router.TOKENS_PER_ETH();
        assertEq(gateway.totalSold(), 15_000_000e18);
        assertEq(gateway.totalBurned(), 1_500_000e18);
        assertEq(gateway.totalToHost(), expectedEth);
        assertEq(host.balance, expectedEth);
    }

    function test_burn_only_settlement_does_not_add_to_sold_or_host_totals() public {
        vm.prank(operator);
        gateway.settle(0, 1_000_000e18, 0);
        assertEq(gateway.totalBurned(), 1_000_000e18);
        assertEq(gateway.totalSold(), 0);
        assertEq(gateway.totalToHost(), 0);
    }

    /// The margin rule (burnAmount * 10 >= sellAmount) is enforced per call; this checks it also
    /// holds in aggregate, and that the lifetime totals always equal the sum of what every
    /// accepted settle() call actually used.
    function testFuzz_settle_burns_at_least_one_eleventh_and_totals_add_up(uint256 sellAmount, uint256 burnAmount)
        public
    {
        uint256 balance = token.balanceOf(address(gateway));
        sellAmount = bound(sellAmount, 0, balance);
        // ceil(sellAmount / 10): the smallest burnAmount that satisfies burnAmount * 10 >= sellAmount.
        uint256 minBurn = sellAmount == 0 ? 1 : (sellAmount + 9) / 10;
        vm.assume(minBurn <= balance - sellAmount);
        burnAmount = bound(burnAmount, minBurn, balance - sellAmount);

        uint256 supplyBefore = token.totalSupply();
        uint256 hostBefore = host.balance;
        uint256 soldBefore = gateway.totalSold();
        uint256 burnedBefore = gateway.totalBurned();
        uint256 toHostBefore = gateway.totalToHost();

        vm.prank(operator);
        uint256 ethToHost = gateway.settle(sellAmount, burnAmount, 0);

        assertGe(burnAmount * 10, sellAmount);
        assertEq(token.totalSupply(), supplyBefore - burnAmount);
        assertEq(host.balance, hostBefore + ethToHost);
        assertEq(gateway.totalSold(), soldBefore + sellAmount);
        assertEq(gateway.totalBurned(), burnedBefore + burnAmount);
        assertEq(gateway.totalToHost(), toHostBefore + ethToHost);
    }

    function test_settle_cannot_be_reentered() public {
        ReentrantHost hostile = new ReentrantHost();
        GatewaySettlement g =
            new GatewaySettlement(IKyzn(address(token)), IUniswapV2Router02(address(router)), address(hostile));
        g.setOperator(address(hostile));
        hostile.setGateway(g);
        // 100,000 more than the settlement uses, so the inner burn could succeed and only the guard stops it.
        token.transfer(address(g), 1_200_000e18);
        // The inner settle reverts, so the router's ETH payment to the host fails.
        vm.expectRevert(bytes("MockRouter: ETH send"));
        hostile.settle(1_000_000e18, 100_000e18);
    }
}
