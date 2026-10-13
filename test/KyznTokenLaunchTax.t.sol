// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {Fixture} from "./utils/Fixture.sol";

/// The launch taxes (SPEC 3.1): trading opens at 5% on buys and 10% on sells; the owner lowers
/// each, never below 4%, and can then renounce ownership, after which nothing in the token can
/// change. Of each trade, at its own tax level, the Reserve keeps 2% and Staking 1%; development
/// receives the rest. Each tax's shares are recorded when it is collected and paid when it sells.
contract KyznTokenLaunchTaxTest is Fixture {
    function setUp() public override {
        super.setUp();
        // At the launch taxes, not lowered; no max wallet.
        token.removeMaxWallet();
    }

    /// ETH the mock router pays for `tokens` of tax.
    function _eth(uint256 tokens) internal view returns (uint256) {
        return tokens / router.TOKENS_PER_ETH();
    }

    /// Untaxed: a wallet-to-wallet transfer from the deployer.
    function _give(address who, uint256 amount) internal {
        token.transfer(who, amount);
    }

    function _recorded() internal view returns (uint256 toReserve, uint256 toStaking) {
        return (token.reserveTaxTokens(), token.stakingTaxTokens());
    }

    function test_the_taxes_start_at_5_percent_on_buys_and_10_on_sells_with_a_4_percent_floor() public view {
        assertEq(token.buyTaxBps(), 500);
        assertEq(token.sellTaxBps(), 1_000);
        assertEq(token.INITIAL_BUY_TAX_BPS(), 500);
        assertEq(token.INITIAL_SELL_TAX_BPS(), 1_000);
        assertEq(token.MIN_TAX_BPS(), 400);
        assertEq(token.RESERVE_BPS(), 200);
        assertEq(token.STAKING_BPS(), 100);
    }

    function test_a_buy_pays_5_percent_a_sell_10_and_a_transfer_nothing() public {
        uint256 gross = 0.01 ether * router.TOKENS_PER_ETH(); // 3,000,000
        assertEq(_buy(alice, 0.01 ether), gross - gross * 5 / 100);
        assertEq(token.balanceOf(address(token)), gross * 5 / 100); // 150,000

        uint256 pairBefore = token.balanceOf(pair);
        vm.prank(alice);
        token.transfer(pair, 1_000_000e18);
        assertEq(token.balanceOf(pair) - pairBefore, 900_000e18);
        assertEq(token.balanceOf(address(token)), 250_000e18); // below the threshold: no swap-back

        vm.prank(alice);
        token.transfer(bob, 1_000e18);
        assertEq(token.balanceOf(bob), 1_000e18);
        assertEq(token.balanceOf(address(token)), 250_000e18);
    }

    function test_each_tax_records_2_and_1_points_of_its_own_trade() public {
        _buy(alice, 0.01 ether); // 150,000 tax at 5%: 2/5 and 1/5 of it
        (uint256 r, uint256 s) = _recorded();
        assertEq(r, 60_000e18);
        assertEq(s, 30_000e18);
        vm.prank(alice);
        token.transfer(pair, 1_000_000e18); // 100,000 tax at 10%: 2/10 and 1/10 of it
        (r, s) = _recorded();
        assertEq(r, 80_000e18);
        assertEq(s, 40_000e18);
    }

    function test_tax_from_5_percent_buys_splits_2_1_2() public {
        _buy(alice, 0.04 ether); // 12,000,000 out, 600,000 tax pending
        uint256 eth = _eth(600_000e18);
        uint256 toReserve = eth * 2 / 5;
        uint256 toStaking = eth / 5;
        vm.startPrank(alice);
        token.approve(address(router), 1_000_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.TaxDistributed(toReserve, toStaking, eth - toReserve - toStaking);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1_000_000e18, 0, _path(address(token), address(weth)), alice, block.timestamp
        );
        vm.stopPrank();
        assertEq(address(reserve).balance, toReserve);
        assertEq(address(staking).balance, toStaking);
        assertEq(token.heldEth(dev), eth - toReserve - toStaking);
        // Left recorded: the shares of that sell's own 100,000 tax, at 10%.
        (uint256 r, uint256 s) = _recorded();
        assertEq(r, 20_000e18);
        assertEq(s, 10_000e18);
        assertEq(token.balanceOf(address(token)), 100_000e18);
    }

    function test_tax_from_10_percent_sells_splits_2_1_7() public {
        // Sells go through the router: tokens sent straight to a pair are the next swap's input.
        _give(alice, 6_000_000e18);
        _sell(alice, 5_000_000e18); // 500,000 tax, at the threshold; no swap-back yet
        uint256 eth = _eth(500_000e18);
        _sell(alice, 1_000_000e18); // sells the 500,000 first
        assertEq(address(reserve).balance, eth * 2 / 10);
        assertEq(address(staking).balance, eth / 10);
        assertEq(token.heldEth(dev), eth - eth * 2 / 10 - eth / 10);
    }

    function test_buy_and_sell_tax_together_split_by_each_trade_s_level() public {
        _buy(alice, 0.02 ether); // 300,000 tax at 5%: 120,000 Reserve, 60,000 Staking
        _give(bob, 4_000_000e18);
        _sell(bob, 3_000_000e18); // 300,000 tax at 10%: 60,000 Reserve, 30,000 Staking
        uint256 eth = _eth(600_000e18);
        _sell(bob, 1_000_000e18); // sells the 600,000 first
        // 180,000 of 600,000 to the Reserve (30%), 90,000 to Staking (15%).
        assertEq(address(reserve).balance, eth * 3 / 10);
        assertEq(address(staking).balance, eth * 15 / 100);
        assertEq(token.heldEth(dev), eth - eth * 3 / 10 - eth * 15 / 100);
    }

    function test_a_partial_swap_back_pays_in_proportion_and_keeps_the_rest_recorded() public {
        _buy(alice, 0.04 ether); // 600,000 tax at 5%: 240,000 Reserve, 120,000 Staking
        _sell(alice, 200_000e18); // the swap-back sells 200,000: never more than the sell
        uint256 eth = _eth(200_000e18);
        assertEq(address(reserve).balance, eth * 2 / 5);
        assertEq(address(staking).balance, eth / 5);
        // A third of each share sold; the sell's own 20,000 tax at 10% added.
        (uint256 r, uint256 s) = _recorded();
        assertEq(r, 160_000e18 + 4_000e18);
        assertEq(s, 80_000e18 + 2_000e18);
        assertEq(token.balanceOf(address(token)), 400_000e18 + 20_000e18);
    }

    function test_the_owner_lowers_each_tax_one_way_to_4_percent_and_never_below() public {
        vm.expectRevert(KyznToken.TaxBelowFloor.selector);
        token.lowerTax(399, 1_000);
        vm.expectRevert(KyznToken.TaxBelowFloor.selector);
        token.lowerTax(500, 399);
        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(501, 900); // the buy tax would rise
        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(400, 1_001); // the sell tax would rise
        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(500, 1_000); // nothing lower

        vm.expectEmit(address(token));
        emit KyznToken.TaxLowered(500, 1_000, 500, 700);
        token.lowerTax(500, 700);
        vm.expectEmit(address(token));
        emit KyznToken.TaxLowered(500, 700, 400, 700);
        token.lowerTax(400, 700);
        token.lowerTax(400, 400);
        assertEq(token.buyTaxBps(), 400);
        assertEq(token.sellTaxBps(), 400);

        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(400, 400);
        vm.expectRevert(KyznToken.TaxBelowFloor.selector);
        token.lowerTax(0, 0);
        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(500, 1_000);
    }

    function test_only_the_owner_lowers_the_tax() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.lowerTax(400, 400);
    }

    function test_at_4_percent_the_split_is_2_1_1() public {
        token.lowerTax(400, 400);
        _buy(alice, 0.05 ether); // 15,000,000 out, 600,000 tax pending
        uint256 eth = _eth(600_000e18);
        _sellAndCheck(eth, eth / 2, eth / 4);
    }

    function test_tax_collected_before_the_owner_lowers_it_keeps_its_split() public {
        _buy(alice, 0.04 ether); // 600,000 tax at 5%
        token.lowerTax(400, 400);
        uint256 eth = _eth(600_000e18);
        _sellAndCheck(eth, eth * 2 / 5, eth / 5); // still 2 : 1 : 2
        (uint256 r, uint256 s) = _recorded();
        assertEq(r, 20_000e18); // the sell's own 40,000 tax at 4%: half and a quarter
        assertEq(s, 10_000e18);
    }

    /// $KYZN sent to the token contract would sell in a later swap-back untaxed and without the
    /// Reserve's and Staking's points (a tax-free route for any holder), so no transfer can.
    function test_kyzn_cannot_be_sent_to_the_token_contract() public {
        vm.expectRevert(KyznToken.TransferToToken.selector);
        token.transfer(address(token), 500_000e18);
        _give(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(KyznToken.TransferToToken.selector);
        token.transfer(address(token), 1_000e18);
        vm.prank(alice);
        token.approve(bob, 1_000e18);
        vm.prank(bob);
        vm.expectRevert(KyznToken.TransferToToken.selector);
        token.transferFrom(alice, address(token), 1_000e18);
        // The tax still arrives: a sell's tax lands in the contract.
        vm.prank(alice);
        token.transfer(pair, 1_000e18);
        assertEq(token.balanceOf(address(token)), 100e18);
    }

    /// Development's share is held in the token and claimed by the development wallet: a sell
    /// never sends ETH to it, so no choice of wallet can stop a sell.
    function test_no_sell_calls_the_development_wallet() public {
        _buy(alice, 0.04 ether); // 600,000 tax at 5%
        vm.expectCall(dev, "", 0); // for the rest of this test
        _sell(alice, 1_000_000e18);
        assertGt(token.heldEth(dev), 0);
    }

    /// Anyone can send development's held share to the development wallet, in a transaction of its
    /// own (the server's worker does): the wallet receives it without acting.
    function test_anyone_sends_the_held_share_to_the_development_wallet() public {
        _buy(alice, 0.04 ether);
        _sell(alice, 1_000_000e18);
        uint256 held = token.heldEth(dev);
        assertGt(held, 0);
        vm.prank(bob);
        vm.expectEmit(address(token));
        emit KyznToken.HeldEthSent(dev, held);
        token.sendHeldEth(dev);
        assertEq(dev.balance, held);
        assertEq(token.heldEth(dev), 0);
        assertEq(token.totalHeldEth(), 0);
        assertEq(address(token).balance, 0);
        vm.expectRevert(KyznToken.NothingHeld.selector);
        token.sendHeldEth(dev);
    }

    /// A wallet that refuses ETH keeps its share held: the send reverts and nothing is lost.
    function test_a_refused_send_keeps_the_share_held() public {
        RefusesAll refuser = new RefusesAll();
        token.setDevWallet(address(refuser));
        _buy(alice, 0.04 ether);
        _sell(alice, 1_000_000e18);
        uint256 held = token.heldEth(address(refuser));
        assertGt(held, 0);
        vm.expectRevert(KyznToken.EthSendFailed.selector);
        token.sendHeldEth(address(refuser));
        assertEq(token.heldEth(address(refuser)), held);
    }

    /// A new development wallet takes the shares from then on; what was held for the old one is
    /// still sent to the old one.
    function test_changing_the_development_wallet_keeps_the_old_wallet_s_held_share() public {
        _buy(alice, 0.04 ether);
        _sell(alice, 1_000_000e18);
        uint256 heldForDev = token.heldEth(dev);
        assertGt(heldForDev, 0);
        token.setDevWallet(bob);
        _buy(alice, 0.04 ether);
        _sell(alice, 1_000_000e18);
        assertEq(token.heldEth(dev), heldForDev);
        assertGt(token.heldEth(bob), 0);
        token.sendHeldEth(dev);
        assertEq(dev.balance, heldForDev);
    }

    function test_after_renouncing_nothing_in_the_token_can_change() public {
        token.lowerTax(400, 400);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this));
        vm.expectRevert(unauthorized);
        token.lowerTax(400, 400);
        vm.expectRevert(unauthorized);
        token.setDevWallet(alice);
        vm.expectRevert(unauthorized);
        token.setSwapThreshold(200_000e18);
        vm.expectRevert(unauthorized);
        token.setProtocolAddresses(alice, bob, dev);
        vm.expectRevert(unauthorized);
        token.removeMaxWallet();
        vm.expectRevert(unauthorized);
        token.transferOwnership(alice);
        // Trading carries on at the frozen 4%.
        uint256 gross = 0.001 ether * router.TOKENS_PER_ETH();
        assertEq(_buy(bob, 0.001 ether), gross - gross * 400 / 10_000);
    }

    /// Alice sells 1,000,000, which first sells the whole pending tax; checks each share.
    function _sellAndCheck(uint256 eth, uint256 toReserve, uint256 toStaking) internal {
        _sell(alice, 1_000_000e18);
        assertEq(address(reserve).balance, toReserve);
        assertEq(address(staking).balance, toStaking);
        assertEq(token.heldEth(dev), eth - toReserve - toStaking);
    }
}

/// Refuses every ETH transfer.
contract RefusesAll {
    receive() external payable {
        revert("no");
    }
}
