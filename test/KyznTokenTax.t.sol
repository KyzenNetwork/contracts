// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {KyznToken} from "../src/KyznToken.sol";
import {Fixture} from "./utils/Fixture.sol";

/// The 4% pool tax and its exemptions (SPEC 3.1).
contract KyznTokenTaxTest is Fixture {
    function setUp() public override {
        super.setUp();
        _launch();
        token.removeMaxWallet();
    }

    function test_buy_pays_4_percent() public {
        uint256 gross = 0.01 ether * router.TOKENS_PER_ETH(); // 3,000,000
        uint256 received = _buy(alice, 0.01 ether);
        assertEq(received, gross - gross * 400 / 10_000);
        assertEq(token.balanceOf(address(token)), gross * 400 / 10_000);
    }

    function test_sell_pays_4_percent() public {
        token.transfer(alice, 1_000_000e18);
        uint256 pairBefore = token.balanceOf(pair);
        uint256 ethOut = _sell(alice, 1_000_000e18);
        assertEq(token.balanceOf(pair) - pairBefore, 960_000e18);
        assertEq(token.balanceOf(address(token)), 40_000e18);
        assertEq(ethOut, 960_000e18 / router.TOKENS_PER_ETH());
    }

    function test_wallet_transfers_are_untaxed() public {
        token.transfer(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(bob, 1_000e18);
        assertEq(token.balanceOf(bob), 1_000e18);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_buy_delivered_to_an_exempt_address_is_untaxed() public {
        vm.deal(alice, 1 ether);
        uint256 before = token.balanceOf(address(staking));
        vm.prank(alice);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.001 ether}(
            0, _path(address(weth), address(token)), address(staking), block.timestamp
        );
        assertEq(token.balanceOf(address(staking)) - before, 0.001 ether * router.TOKENS_PER_ETH());
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_sell_from_an_exempt_address_is_untaxed() public {
        token.transfer(address(gateway), 1_000_000e18);
        uint256 pairBefore = token.balanceOf(pair);
        vm.prank(address(gateway));
        token.transfer(pair, 1_000_000e18);
        assertEq(token.balanceOf(pair) - pairBefore, 1_000_000e18);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_the_4_percent_tax_applies_after_the_launch_tax_is_lowered() public {
        uint256 gross = 0.001 ether * router.TOKENS_PER_ETH();
        assertEq(_buy(alice, 0.001 ether), gross - gross * 4 / 100);
    }

    function testFuzz_sell_tax_is_exact(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000e18); // tax stays below the swap threshold
        uint256 bps = token.sellTaxBps();
        token.transfer(alice, amount);
        uint256 pairBefore = token.balanceOf(pair);
        vm.prank(alice);
        token.transfer(pair, amount);
        uint256 tax = amount * bps / 10_000;
        assertEq(token.balanceOf(pair) - pairBefore, amount - tax);
        assertEq(token.balanceOf(address(token)), tax);
        assertEq(token.reserveTaxTokens(), tax * 200 / bps);
        assertEq(token.stakingTaxTokens(), tax * 100 / bps);
    }
}

/// The 2% max wallet on buys from the pool, from deployment until the owner removes it (SPEC 3.1).
contract KyznTokenMaxWalletTest is Fixture {
    function setUp() public override {
        super.setUp();
        _launch();
    }

    function test_on_from_deployment_until_the_owner_removes_it() public {
        assertTrue(token.maxWalletActive());
        vm.warp(block.timestamp + 365 days);
        assertTrue(token.maxWalletActive());
        token.removeMaxWallet();
        assertFalse(token.maxWalletActive());
    }

    function test_buy_above_2_percent_reverts() public {
        // 0.07 ETH buys 21,000,000 gross, 20,160,000 after tax
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(KyznToken.MaxWalletExceeded.selector);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.07 ether}(
            0, _path(address(weth), address(token)), alice, block.timestamp
        );
    }

    function test_buy_below_2_percent_passes() public {
        // 0.069 ETH buys 20,700,000 gross, 19,872,000 after tax
        assertEq(_buy(alice, 0.069 ether), 19_872_000e18);
    }

    /// The limit is inclusive: a buy that leaves the wallet holding exactly 2% of supply passes;
    /// one more wei reverts.
    function test_a_buy_landing_exactly_on_2_percent_passes_and_one_wei_more_reverts() public {
        uint256 ethIn = 0.001 ether;
        uint256 gross = ethIn * router.TOKENS_PER_ETH();
        uint256 net = gross - gross * 400 / 10_000;
        uint256 cap = token.MAX_WALLET();

        token.transfer(alice, cap - net);
        assertEq(_buy(alice, ethIn), net);
        assertEq(token.balanceOf(alice), cap);

        token.transfer(bob, cap - net + 1);
        vm.deal(bob, ethIn);
        vm.prank(bob);
        vm.expectRevert(KyznToken.MaxWalletExceeded.selector);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            0, _path(address(weth), address(token)), bob, block.timestamp
        );
        assertEq(token.balanceOf(bob), cap - net + 1);
    }

    /// Staking is exempt: a Compound claim, a buy from the pool delivered to Staking, may take far
    /// more than 2% of supply in one buy while the max wallet is on, untaxed.
    function test_a_compound_buy_for_staking_above_2_percent_is_neither_limited_nor_taxed() public {
        token.transfer(alice, 1_000_000e18);
        vm.startPrank(alice);
        token.approve(address(staking), 1_000_000e18);
        staking.stake(1_000_000e18);
        vm.stopPrank();
        _taxEthToStaking(0.1 ether);
        staking.notifyRewards();
        vm.warp(block.timestamp + 24 hours);
        uint256 gross = staking.earned(alice) * router.TOKENS_PER_ETH();
        assertGt(gross, token.MAX_WALLET()); // about 30,000,000 $KYZN in one buy

        assertTrue(token.maxWalletActive());
        vm.prank(alice);
        uint256 added = staking.claimCompound(0);
        assertEq(added, gross); // no tax taken
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(staking)), 1_000_000e18 + gross);
        assertEq(staking.stakedOf(alice), 1_000_000e18 + gross);
    }

    /// A buy that would take a wallet's total past 2% reverts too.
    function test_a_buy_onto_a_holding_counts_the_holding() public {
        token.transfer(alice, 19_000_000e18);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(KyznToken.MaxWalletExceeded.selector);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.01 ether}(
            0, _path(address(weth), address(token)), alice, block.timestamp
        );
    }

    /// The limit holds buys only: wallet transfers (the team stream's withdrawals among them) and
    /// unstaking are not limited.
    function test_wallet_transfers_and_unstaking_are_not_limited() public {
        token.transfer(alice, 15_000_000e18);
        token.transfer(bob, 15_000_000e18);
        vm.prank(alice);
        token.transfer(bob, 15_000_000e18);
        assertEq(token.balanceOf(bob), 30_000_000e18);

        token.transfer(carol, 15_000_000e18);
        vm.startPrank(bob);
        token.approve(address(staking), 15_000_000e18);
        staking.stake(15_000_000e18);
        vm.stopPrank();
        vm.prank(carol);
        token.transfer(bob, 15_000_000e18);
        vm.prank(bob);
        staking.withdraw(15_000_000e18);
        assertEq(token.balanceOf(bob), 45_000_000e18);
    }

    /// Buys from the pool delivered to the Reserve or the Gateway are neither limited nor taxed.
    /// (Staking's: test_a_compound_buy_for_staking_above_2_percent_is_neither_limited_nor_taxed.)
    function test_protocol_contracts_are_not_limited() public {
        uint256 gross = 0.1 ether * router.TOKENS_PER_ETH(); // 30,000,000: 3% of supply
        assertGt(gross, token.MAX_WALLET());
        address[2] memory protocol = [address(reserve), address(gateway)];
        vm.deal(alice, 1 ether);
        for (uint256 i; i < protocol.length; ++i) {
            vm.prank(alice);
            router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.1 ether}(
                0, _path(address(weth), address(token)), protocol[i], block.timestamp
            );
            assertEq(token.balanceOf(protocol[i]), gross);
        }
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_removed_lets_a_buy_above_2_percent_through() public {
        token.removeMaxWallet();
        uint256 gross = 0.07 ether * router.TOKENS_PER_ETH();
        assertEq(_buy(alice, 0.07 ether), gross - gross * 400 / 10_000);
    }
}
