// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {Fixture} from "./utils/Fixture.sol";
import {GasBurner, RejectingReceiver} from "./mocks/Receivers.sol";
import {PayableProtocolStub} from "./mocks/ProtocolStub.sol";

/// Tax settlement: the swap on sells and the 2 : 1 : 1 ETH split (SPEC 3.1).
contract KyznTokenSwapTest is Fixture {
    /// The gas a test sell is given when a recipient burns gas: enough for the sell with each
    /// burner capped at SEND_GAS, far too little without the cap (a burner would then take all but
    /// 1/64 of the gas left, about 12,000, and the sell would run out).
    uint256 internal constant SELL_GAS_BUDGET = 1_000_000;

    function setUp() public override {
        super.setUp();
        _launch();
        token.removeMaxWallet();
    }

    /// ETH the mock router pays for `tokens` of tax.
    function _eth(uint256 tokens) internal view returns (uint256) {
        return tokens / router.TOKENS_PER_ETH();
    }

    function test_no_swap_below_threshold() public {
        _buy(alice, 0.01 ether); // tax 120,000
        _sell(alice, 1_000_000e18); // tax 40,000; 120,000 pending is below 500,000
        assertEq(token.balanceOf(address(token)), 160_000e18);
        assertEq(address(reserve).balance, 0);
    }

    function test_buys_never_swap() public {
        _buy(alice, 0.05 ether); // tax 600,000
        _buy(bob, 0.05 ether); // 600,000 pending, but a buy
        assertEq(token.balanceOf(address(token)), 1_200_000e18);
    }

    function test_sell_swaps_and_splits_2_1_1() public {
        _buy(alice, 0.05 ether); // 600,000 pending
        uint256 eth = _eth(600_000e18);
        vm.startPrank(alice);
        token.approve(address(router), 1_000_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.TaxSwapped(600_000e18, eth);
        vm.expectEmit(address(token));
        emit KyznToken.EthHeld(dev, eth - eth / 2 - eth / 4); // development's share, held for its wallet
        vm.expectEmit(address(token));
        emit KyznToken.TaxDistributed(eth / 2, eth / 4, eth - eth / 2 - eth / 4);
        // swaps min(600,000 pending, 1,000,000 sold, 0.25% of the pool's $KYZN)
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1_000_000e18, 0, _path(address(token), address(weth)), alice, block.timestamp
        );
        vm.stopPrank();
        assertEq(address(reserve).balance, eth / 2);
        assertEq(address(staking).balance, eth / 4);
        assertEq(token.heldEth(dev), eth - eth / 2 - eth / 4);
        assertEq(token.balanceOf(address(token)), 40_000e18); // this sell's own tax
    }

    /// The pool bound: however much tax is pending and however large the sell, one swap-back sells
    /// at most 0.25% of the pool's $KYZN, so it moves the price a seller meets by about 0.5% at most.
    function test_a_large_sell_swaps_at_most_a_quarter_percent_of_the_pool() public {
        address seller = makeAddr("seller");
        token.transfer(seller, 50_000_000e18);
        _setPendingTax(10_000_000e18); // well above the pool bound
        uint256 bound = token.balanceOf(pair) * token.SWAP_POOL_BPS() / token.BPS();
        assertLt(bound, 10_000_000e18);

        vm.startPrank(seller);
        token.approve(address(router), 20_000_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.TaxSwapped(bound, _eth(bound));
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            20_000_000e18, 0, _path(address(token), address(weth)), seller, block.timestamp
        );
        vm.stopPrank();
        // The rest stays pending for later sells, plus this sell's own 4% tax.
        assertEq(token.balanceOf(address(token)), 10_000_000e18 - bound + 800_000e18);
    }

    /// Below the pool bound, a sell larger than the pending tax clears all of it in one swap-back.
    function test_a_sell_larger_than_the_pending_tax_clears_it_below_the_pool_bound() public {
        for (uint256 i; i < 2; ++i) {
            _buy(address(uint160(0x1000 + i)), 0.05 ether); // 1,200,000 pending
        }
        assertLt(1_200_000e18, token.balanceOf(pair) * token.SWAP_POOL_BPS() / token.BPS());
        address seller = makeAddr("seller");
        token.transfer(seller, 5_000_000e18);
        _sell(seller, 5_000_000e18);
        // all 1,200,000 sold in one swap-back; only this sell's own 200,000 tax is left
        assertEq(token.balanceOf(address(token)), 200_000e18);
    }

    /// The seller bound: a sell smaller than the pending tax swaps only its own size.
    function test_a_sell_below_the_pending_tax_swaps_only_its_own_size() public {
        for (uint256 i; i < 2; ++i) {
            _buy(address(uint160(0x1000 + i)), 0.05 ether); // 1,200,000 pending
        }
        address seller = makeAddr("seller");
        token.transfer(seller, 1_000_000e18);
        _sell(seller, 1_000_000e18);
        // 1,000,000 sold; 200,000 left plus this sell's own 40,000 tax
        assertEq(token.balanceOf(address(token)), 240_000e18);
    }

    /// The bound follows the pool: after buys take $KYZN out of the pool, a swap-back sells less.
    function test_the_pool_bound_shrinks_with_the_pool() public {
        uint256 boundBefore = token.balanceOf(pair) * token.SWAP_POOL_BPS() / token.BPS();
        _buy(alice, 1 ether); // 300,000,000 $KYZN out of the pool; 12,000,000 tax pending
        uint256 bound = token.balanceOf(pair) * token.SWAP_POOL_BPS() / token.BPS();
        assertEq(bound, 600_000_000e18 * 25 / 10_000);
        assertLt(bound, boundBefore);

        address seller = makeAddr("seller");
        token.transfer(seller, 20_000_000e18);
        uint256 pending = token.balanceOf(address(token));
        vm.startPrank(seller);
        token.approve(address(router), 20_000_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.TaxSwapped(bound, _eth(bound));
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            20_000_000e18, 0, _path(address(token), address(weth)), seller, block.timestamp
        );
        vm.stopPrank();
        assertEq(token.balanceOf(address(token)), pending - bound + 800_000e18);
    }

    /// Whatever is pending and however large the sell, a swap-back sells at most the pool bound
    /// and never more than the sell.
    function testFuzz_swap_back_never_exceeds_the_pool_bound_or_the_sell(uint256 pending, uint256 sold) public {
        pending = bound(pending, token.swapThreshold(), 45_000_000e18); // the owner holds 100,000,000
        sold = bound(sold, 1e18, 50_000_000e18);
        address seller = makeAddr("seller");
        token.transfer(seller, sold);
        _setPendingTax(pending);
        uint256 poolBound = token.balanceOf(pair) * token.SWAP_POOL_BPS() / token.BPS();
        uint256 expected = pending < sold ? pending : sold;
        if (poolBound < expected) expected = poolBound;

        _sell(seller, sold);
        assertEq(token.balanceOf(address(token)), pending - expected + sold * 400 / 10_000);
        assertLe(expected, poolBound);
        assertLe(expected, sold);
    }

    function test_swap_never_exceeds_the_triggering_sell() public {
        _buy(alice, 0.05 ether); // 600,000 pending
        _sell(alice, 100_000e18); // swaps 100,000, adds 4,000
        assertEq(token.balanceOf(address(token)), 504_000e18);
    }

    function test_exempt_sell_does_not_swap() public {
        _buy(alice, 0.05 ether); // 600,000 pending
        token.transfer(address(gateway), 1_000_000e18);
        vm.prank(address(gateway));
        token.transfer(pair, 1_000_000e18);
        assertEq(token.balanceOf(address(token)), 600_000e18);
    }

    /// Development's share is held, never sent during a sell: a development wallet that refuses
    /// ETH cannot block one. Sending it the held ETH fails and leaves it held; a new wallet takes
    /// the shares from then on.
    function test_a_development_wallet_that_refuses_eth_never_blocks_a_sell() public {
        RejectingReceiver rejecter = new RejectingReceiver();
        token.setDevWallet(address(rejecter));
        _buy(alice, 0.05 ether);
        _sell(alice, 1_000_000e18);
        uint256 eth = _eth(600_000e18);
        uint256 devShare = eth - eth / 2 - eth / 4;
        assertEq(token.heldEth(address(rejecter)), devShare);
        assertEq(token.totalHeldEth(), devShare);
        assertEq(address(token).balance, devShare);

        vm.expectRevert(KyznToken.EthSendFailed.selector);
        token.sendHeldEth(address(rejecter));
        assertEq(token.heldEth(address(rejecter)), devShare);

        token.setDevWallet(bob);
        _buy(alice, 0.05 ether);
        _sell(alice, 1_000_000e18);
        token.sendHeldEth(bob);
        assertGt(bob.balance, 0);
    }

    function test_sending_with_nothing_held_reverts() public {
        vm.expectRevert(KyznToken.NothingHeld.selector);
        token.sendHeldEth(alice);
    }

    function test_a_gas_burning_development_wallet_cannot_block_sells() public {
        GasBurner burner = new GasBurner();
        token.setDevWallet(address(burner));
        _buy(alice, 0.05 ether);
        _sell(alice, 1_000_000e18);
        assertGt(token.heldEth(address(burner)), 0);
    }

    function test_failed_swap_does_not_block_the_sell() public {
        _buy(alice, 0.05 ether); // 600,000 pending
        router.setFailFor(address(token));
        vm.startPrank(alice);
        token.approve(address(router), 1_000_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.TaxSwapFailed(600_000e18);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1_000_000e18, 0, _path(address(token), address(weth)), alice, block.timestamp
        );
        vm.stopPrank();
        assertEq(token.balanceOf(address(token)), 640_000e18);
        assertEq(token.allowance(address(token), address(router)), 0);
    }

    function test_only_the_router_sends_eth_and_only_during_a_swap_back() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
        // The router outside a swap-back, as when a swap names the token as its recipient.
        vm.deal(address(router), 1 ether);
        vm.prank(address(router));
        (ok,) = address(token).call{value: 1}("");
        assertFalse(ok);
        assertEq(address(token).balance, 0);
    }

    /// A sell that names the token as the recipient of its ETH reverts instead of leaving the ETH
    /// in the token for good.
    function test_a_swap_paying_eth_to_the_token_reverts() public {
        _buy(alice, 0.01 ether);
        vm.startPrank(alice);
        token.approve(address(router), 1_000_000e18);
        vm.expectRevert();
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1_000_000e18, 0, _path(address(token), address(weth)), address(token), block.timestamp
        );
        vm.stopPrank();
    }

    function test_lower_threshold_swaps_sooner() public {
        token.setSwapThreshold(100_000e18);
        _buy(alice, 0.01 ether); // 120,000 pending
        _sell(alice, 1_000_000e18);
        assertEq(token.balanceOf(address(token)), 40_000e18);
    }

    /// A zero-value transfer to the pair (e.g. a probe or an approval-style call) never
    /// attempts the swap-back, even with tax pending well above the threshold.
    function test_zero_value_transfer_to_the_pair_does_not_attempt_a_tax_swap() public {
        _buy(bob, 0.05 ether); // 600,000 pending, above the threshold
        uint256 pendingBefore = token.balanceOf(address(token));

        vm.recordLogs();
        vm.prank(carol);
        token.transfer(pair, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(token)) continue;
            assertTrue(
                logs[i].topics[0] != KyznToken.TaxSwapped.selector
                    && logs[i].topics[0] != KyznToken.TaxSwapFailed.selector,
                "a zero-value transfer attempted a tax swap"
            );
        }
        assertEq(token.balanceOf(address(token)), pendingBefore);
        assertEq(address(reserve).balance, 0);
    }

    /// Pending exactly at the threshold swaps; one below does not (the trigger is `>=`).
    function test_swap_back_starts_exactly_at_the_threshold() public {
        token.transfer(alice, 10_000e18);
        uint256 threshold = token.swapThreshold();

        _setPendingTax(threshold - 1);
        _sell(alice, 1_000e18);
        assertEq(address(reserve).balance, 0);
        assertEq(token.balanceOf(address(token)), threshold - 1 + 1_000e18 * 400 / 10_000);

        _setPendingTax(threshold);
        uint256 eth = _eth(1_000e18);
        vm.startPrank(alice);
        token.approve(address(router), 1_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.TaxSwapped(1_000e18, eth);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1_000e18, 0, _path(address(token), address(weth)), alice, block.timestamp
        );
        vm.stopPrank();
        assertGt(address(reserve).balance, 0);
    }

    // ---------------------------------------------------------------- recipients that refuse ETH

    /// A Reserve and Staking that refuse ETH never block a sell: each share is held for its
    /// recipient (EthHeld), and sendHeldEth reverts, keeping it held, until the recipient accepts.
    function test_a_reserve_and_staking_that_refuse_eth_never_block_a_sell() public {
        _buy(alice, 0.05 ether); // 600,000 pending
        (PayableProtocolStub r, PayableProtocolStub s, address g) =
            _payableStubs(token, PayableProtocolStub.Mode.Refuse, PayableProtocolStub.Mode.Refuse);
        token.setProtocolAddresses(address(r), address(s), g);
        uint256 eth = _eth(600_000e18);
        uint256 toReserve = eth / 2;
        uint256 toStaking = eth / 4;
        uint256 toDev = eth - toReserve - toStaking;

        vm.startPrank(alice);
        token.approve(address(router), 1_000_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.EthHeld(address(r), toReserve);
        vm.expectEmit(address(token));
        emit KyznToken.EthHeld(address(s), toStaking);
        vm.expectEmit(address(token));
        emit KyznToken.EthHeld(dev, toDev);
        vm.expectEmit(address(token));
        emit KyznToken.TaxDistributed(toReserve, toStaking, toDev);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1_000_000e18, 0, _path(address(token), address(weth)), alice, block.timestamp
        );
        vm.stopPrank();

        assertEq(token.heldEth(address(r)), toReserve);
        assertEq(token.heldEth(address(s)), toStaking);
        assertEq(token.heldEth(dev), toDev);
        assertEq(token.totalHeldEth(), eth);
        assertEq(address(token).balance, token.totalHeldEth());
        assertEq(address(r).balance, 0);
        assertEq(address(s).balance, 0);

        // While the refusal lasts, a send reverts and the share stays held.
        vm.expectRevert(KyznToken.EthSendFailed.selector);
        token.sendHeldEth(address(r));
        vm.expectRevert(KyznToken.EthSendFailed.selector);
        token.sendHeldEth(address(s));
        assertEq(token.heldEth(address(r)), toReserve);
        assertEq(token.heldEth(address(s)), toStaking);

        // Once the Reserve accepts ETH, anyone sends it its share; Staking's stays held.
        r.setMode(PayableProtocolStub.Mode.Accept);
        vm.prank(bob);
        token.sendHeldEth(address(r));
        assertEq(address(r).balance, toReserve);
        assertEq(token.heldEth(address(r)), 0);
        assertEq(token.heldEth(address(s)), toStaking);
        assertEq(token.totalHeldEth(), toStaking + toDev);
        assertEq(address(token).balance, token.totalHeldEth());
    }

    /// A Reserve and Staking that burn all the gas they get cost a sell at most SEND_GAS each: the
    /// sell completes within SELL_GAS_BUDGET, and both shares are held.
    function test_a_reserve_and_staking_that_burn_gas_never_block_a_sell() public {
        _buy(alice, 0.05 ether); // 600,000 pending
        (PayableProtocolStub r, PayableProtocolStub s, address g) =
            _payableStubs(token, PayableProtocolStub.Mode.BurnGas, PayableProtocolStub.Mode.BurnGas);
        token.setProtocolAddresses(address(r), address(s), g);
        uint256 eth = _eth(600_000e18);
        uint256 toReserve = eth / 2;
        uint256 toStaking = eth / 4;

        vm.startPrank(alice);
        token.approve(address(router), 1_000_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.EthHeld(address(r), toReserve);
        vm.expectEmit(address(token));
        emit KyznToken.EthHeld(address(s), toStaking);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens{gas: SELL_GAS_BUDGET}(
            1_000_000e18, 0, _path(address(token), address(weth)), alice, block.timestamp
        );
        vm.stopPrank();

        assertEq(token.balanceOf(address(token)), 40_000e18); // the tax sold; this sell's own 4% left
        assertEq(token.heldEth(address(r)), toReserve);
        assertEq(token.heldEth(address(s)), toStaking);
        assertEq(token.totalHeldEth(), eth);
        assertEq(address(token).balance, token.totalHeldEth());

        // sendHeldEth forwards all its gas, and a burner takes it all: the send reverts.
        vm.expectRevert(KyznToken.EthSendFailed.selector);
        token.sendHeldEth{gas: SELL_GAS_BUDGET}(address(s));
        assertEq(token.heldEth(address(s)), toStaking);
        s.setMode(PayableProtocolStub.Mode.Accept);
        token.sendHeldEth(address(s));
        assertEq(address(s).balance, toStaking);
        assertEq(address(token).balance, token.totalHeldEth());
    }

    /// A recipient that calls sendHeldEth for itself again from its receive() gets its share once:
    /// the held amount is cleared before the send, so the second call finds nothing held.
    function test_send_held_eth_pays_a_reentering_recipient_once() public {
        _buy(alice, 0.05 ether);
        _sell(alice, 1_000_000e18); // development's share held for dev
        uint256 heldForDev = token.heldEth(dev);
        assertGt(heldForDev, 0);
        ReentrantRecipient reentrant = new ReentrantRecipient(token);
        token.setDevWallet(address(reentrant));
        _buy(alice, 0.05 ether);
        _sell(alice, 1_000_000e18);
        uint256 share = token.heldEth(address(reentrant));
        assertGt(share, 0);
        uint256 totalBefore = token.totalHeldEth();

        token.sendHeldEth(address(reentrant));

        assertTrue(reentrant.reentered());
        assertFalse(reentrant.reentrySucceeded());
        assertEq(bytes4(reentrant.reentryError()), KyznToken.NothingHeld.selector);
        assertEq(address(reentrant).balance, share);
        assertEq(token.heldEth(address(reentrant)), 0);
        assertEq(token.heldEth(dev), heldForDev);
        assertEq(token.totalHeldEth(), totalBefore - share);
        assertEq(address(token).balance, token.totalHeldEth());
    }

    // ---------------------------------------------------------------- protocol address changes

    /// Tax recorded while one set of protocol addresses was in place is paid, at the next sale, to
    /// the set in place then: exactly the recorded shares to the new Reserve and Staking, nothing
    /// to the old.
    function test_after_new_protocol_addresses_the_next_sale_pays_the_new_recipients_only() public {
        _buy(alice, 0.05 ether); // 600,000 pending, recorded under the fixture's addresses
        (PayableProtocolStub r, PayableProtocolStub s, address g) =
            _payableStubs(token, PayableProtocolStub.Mode.Accept, PayableProtocolStub.Mode.Accept);
        token.setProtocolAddresses(address(r), address(s), g);

        _sell(alice, 1_000_000e18);

        uint256 eth = _eth(600_000e18);
        assertEq(address(r).balance, eth / 2);
        assertEq(address(s).balance, eth / 4);
        assertEq(token.heldEth(dev), eth - eth / 2 - eth / 4);
        assertEq(address(reserve).balance, 0);
        assertEq(address(staking).balance, 0);
        assertEq(token.heldEth(address(reserve)), 0);
        assertEq(token.heldEth(address(staking)), 0);
        assertEq(token.heldEth(address(r)), 0);
        assertEq(token.heldEth(address(s)), 0);
        assertEq(address(token).balance, token.totalHeldEth());
    }

    /// A pool with liquidity but a token with no protocol addresses yet: trades are taxed and the
    /// Reserve's and Staking's shares recorded, but with no one to pay nothing is sold, past the
    /// threshold or not, and no ETH arrives. Once the addresses are set, the next sell sells it.
    function test_without_protocol_addresses_the_tax_is_recorded_and_held_unsold() public {
        KyznToken fresh = new KyznToken(IUniswapV2Router02(address(router)), dev);
        fresh.removeMaxWallet();
        fresh.approve(address(router), LIQUIDITY_TOKENS);
        router.addLiquidityETH{value: 2 ether}(address(fresh), LIQUIDITY_TOKENS, 0, 0, address(this), block.timestamp);
        assertEq(fresh.balanceOf(address(fresh)), 0); // the first liquidity went in untaxed

        vm.deal(alice, 1 ether);
        vm.prank(alice);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.05 ether}(
            0, _path(address(weth), address(fresh)), alice, block.timestamp
        ); // 15,000,000 out of the pool: 750,000 tax at 5%
        assertEq(fresh.balanceOf(address(fresh)), 750_000e18);
        assertGt(fresh.balanceOf(address(fresh)), fresh.swapThreshold());

        vm.startPrank(alice);
        fresh.approve(address(router), 1_000_000e18);
        vm.recordLogs();
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1_000_000e18, 0, _path(address(fresh), address(weth)), alice, block.timestamp
        ); // 100,000 tax at 10%
        vm.stopPrank();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(fresh)) continue;
            bytes32 topic = logs[i].topics[0];
            assertTrue(
                topic != KyznToken.TaxSwapped.selector && topic != KyznToken.TaxSwapFailed.selector
                    && topic != KyznToken.EthHeld.selector,
                "a sale ran with no protocol addresses"
            );
        }
        assertEq(address(fresh).balance, 0);
        assertEq(fresh.totalHeldEth(), 0);
        assertEq(fresh.balanceOf(address(fresh)), 850_000e18);
        assertEq(fresh.reserveTaxTokens(), 300_000e18 + 20_000e18); // 2/5 of the buy's, 2/10 of the sell's
        assertEq(fresh.stakingTaxTokens(), 150_000e18 + 10_000e18);

        (PayableProtocolStub r, PayableProtocolStub s, address g) =
            _payableStubs(fresh, PayableProtocolStub.Mode.Accept, PayableProtocolStub.Mode.Accept);
        fresh.setProtocolAddresses(address(r), address(s), g);
        uint256 eth = _eth(850_000e18);
        vm.startPrank(alice);
        fresh.approve(address(router), 1_000_000e18);
        vm.expectEmit(address(fresh));
        emit KyznToken.TaxSwapped(850_000e18, eth);
        router.swapExactTokensForETHSupportingFeeOnTransferTokens(
            1_000_000e18, 0, _path(address(fresh), address(weth)), alice, block.timestamp
        );
        vm.stopPrank();
        assertEq(address(r).balance, eth * 320_000 / 850_000);
        assertEq(address(s).balance, eth * 160_000 / 850_000);
        assertEq(address(fresh).balance, fresh.totalHeldEth());
    }

    /// Sets the token contract's own pending-tax balance to an exact value, up or down, without
    /// going through the swap logic itself (written to storage: no transfer can reach the token
    /// contract). Nothing is recorded for the Reserve or Staking for the amount written.
    function _setPendingTax(uint256 amount) internal {
        deal(address(token), address(token), amount);
    }
}

/// Calls sendHeldEth for itself once more from receive(), and records how that call ended.
contract ReentrantRecipient {
    KyznToken public immutable token;
    bool public reentered;
    bool public reentrySucceeded;
    bytes public reentryError;

    constructor(KyznToken token_) {
        token = token_;
    }

    receive() external payable {
        if (reentered) return;
        reentered = true;
        try token.sendHeldEth(address(this)) {
            reentrySucceeded = true;
        } catch (bytes memory reason) {
            reentryError = reason;
        }
    }
}
