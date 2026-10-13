// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Staking} from "../src/Staking.sol";
import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {IReserveView} from "../src/interfaces/IReserveView.sol";
import {Fixture} from "./utils/Fixture.sol";

/// Unlocked staking, 24-hour funding streamed per second, pull-based claims (SPEC 3.3).
contract StakingTest is Fixture {
    function setUp() public override {
        super.setUp();
        token.transfer(alice, 10_000_000e18);
        token.transfer(bob, 10_000_000e18);
        token.transfer(carol, 10_000_000e18);
        _launch();
        token.removeMaxWallet();
    }

    function _stake(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    /// What one funding of `funded` wei streams: whole wei per second over 86,400 seconds.
    function _streamed(uint256 funded) internal pure returns (uint256) {
        return funded / 86_400 * 86_400;
    }

    /// ETH from anyone but the token would stream to stakers and, through Compound, buy $KYZN
    /// untaxed for a staker holding nearly all of the stake.
    function test_takes_eth_from_the_token_only() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory reason) = address(staking).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(reason), Staking.NotTokenOrFeeSource.selector);
        _taxEthToStaking(1 ether);
        assertEq(address(staking).balance, 1 ether);
    }

    /// The owner names one fee source, a protocol contract forwarding later revenue to stakers.
    function test_takes_eth_from_the_fee_source_the_owner_names() public {
        address source = makeAddr("feeRouter");
        vm.deal(source, 2 ether);
        vm.prank(source);
        (bool ok,) = address(staking).call{value: 1 ether}("");
        assertFalse(ok);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setFeeSource(source);
        vm.expectEmit(address(staking));
        emit Staking.FeeSourceSet(source);
        staking.setFeeSource(source);
        vm.prank(source);
        (ok,) = address(staking).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(staking).balance, 1 ether);

        staking.setFeeSource(address(0));
        vm.prank(source);
        (ok,) = address(staking).call{value: 1 ether}("");
        assertFalse(ok);
    }

    /// A fee source is one sender more, not a replacement: anyone else is still refused, and the
    /// fee source and the token both send.
    function test_with_a_fee_source_set_only_it_and_the_token_send_eth() public {
        address source = makeAddr("feeRouter");
        staking.setFeeSource(source);
        assertEq(staking.feeSource(), source);
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        (bool ok, bytes memory reason) = address(staking).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(reason), Staking.NotTokenOrFeeSource.selector);
        vm.deal(source, 1 ether);
        vm.prank(source);
        (ok,) = address(staking).call{value: 1 ether}("");
        assertTrue(ok);
        _taxEthToStaking(1 ether);
        assertEq(address(staking).balance, 2 ether);
    }

    function test_the_constructor_rejects_zero_addresses() public {
        IERC20 kyzn = IERC20(address(token));
        IUniswapV2Router02 r = IUniswapV2Router02(address(router));
        IReserveView v = IReserveView(address(reserve));
        vm.expectRevert(Staking.ZeroAddress.selector);
        new Staking(IERC20(address(0)), r, v, address(nvda), address(amd));
        vm.expectRevert(Staking.ZeroAddress.selector);
        new Staking(kyzn, IUniswapV2Router02(address(0)), v, address(nvda), address(amd));
        vm.expectRevert(Staking.ZeroAddress.selector);
        new Staking(kyzn, r, IReserveView(address(0)), address(nvda), address(amd));
        vm.expectRevert(Staking.ZeroAddress.selector);
        new Staking(kyzn, r, v, address(0), address(amd));
        vm.expectRevert(Staking.ZeroAddress.selector);
        new Staking(kyzn, r, v, address(nvda), address(0));
        Staking fresh = new Staking(kyzn, r, v, address(nvda), address(amd));
        assertEq(address(fresh.weth()), address(weth));
        assertEq(fresh.feeSource(), address(0));
        assertFalse(fresh.equityEnabled());
    }

    /// Sends ETH to Staking the way the token's tax split does.
    function _fund(uint256 amount) internal {
        _taxEthToStaking(amount);
    }

    function test_stake_and_unstake_without_a_lock() public {
        _stake(alice, 1_000e18);
        assertEq(staking.stakedOf(alice), 1_000e18);
        assertEq(staking.totalStaked(), 1_000e18);
        vm.prank(alice);
        staking.withdraw(1_000e18);
        assertEq(staking.stakedOf(alice), 0);
        assertEq(staking.totalStaked(), 0);
        assertEq(token.balanceOf(alice), 10_000_000e18);
    }

    function test_staking_moves_are_untaxed() public {
        _stake(alice, 1_000_000e18);
        vm.prank(alice);
        staking.withdraw(1_000_000e18);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(alice), 10_000_000e18);
    }

    function test_zero_amounts_revert() public {
        vm.startPrank(alice);
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.stake(0);
        vm.expectRevert(Staking.ZeroAmount.selector);
        staking.withdraw(0);
        vm.stopPrank();
    }

    function test_cannot_withdraw_more_than_staked() public {
        _stake(alice, 1_000e18);
        vm.prank(alice);
        vm.expectRevert(stdError.arithmeticError);
        staking.withdraw(1_000e18 + 1);
    }

    function test_first_funding_any_time_then_every_24_hours() public {
        assertLe(staking.nextFundingAt(), block.timestamp);
        staking.notifyRewards();
        assertEq(staking.nextFundingAt(), block.timestamp + 24 hours);
        vm.warp(block.timestamp + 24 hours - 1);
        vm.expectRevert(Staking.TooSoon.selector);
        staking.notifyRewards();
        vm.warp(block.timestamp + 1);
        staking.notifyRewards();
    }

    function test_single_staker_receives_the_whole_day() public {
        _stake(alice, 1_000e18);
        _fund(1 ether);
        vm.expectEmit(address(staking));
        emit Staking.RewardsNotified(_streamed(1 ether), block.timestamp + 24 hours);
        staking.notifyRewards();
        vm.warp(block.timestamp + 24 hours);
        uint256 streamed = _streamed(1 ether);
        assertApproxEqAbs(staking.earned(alice), streamed, 1);
        uint256 before = alice.balance;
        vm.prank(alice);
        uint256 paid = staking.claim();
        assertEq(alice.balance - before, paid);
        assertApproxEqAbs(paid, streamed, 1);
    }

    function test_stakers_share_pro_rata() public {
        _stake(alice, 3_000e18);
        _stake(bob, 1_000e18);
        _fund(4 ether);
        staking.notifyRewards();
        vm.warp(block.timestamp + 24 hours);
        uint256 streamed = _streamed(4 ether);
        assertApproxEqAbs(staking.earned(alice), streamed * 3 / 4, 2);
        assertApproxEqAbs(staking.earned(bob), streamed / 4, 2);
    }

    function test_rewards_accrue_per_second() public {
        _stake(alice, 1_000e18);
        _fund(1 ether);
        staking.notifyRewards();
        uint256 rate = staking.rewardRate();
        vm.warp(block.timestamp + 1);
        assertApproxEqAbs(staking.earned(alice), rate, 1);
        vm.warp(block.timestamp + 6 hours - 1);
        assertApproxEqAbs(staking.earned(alice), rate * 6 hours, 1);
    }

    function test_joining_mid_stream_earns_from_the_join() public {
        _stake(alice, 1_000e18);
        _fund(1 ether);
        staking.notifyRewards();
        uint256 rate = staking.rewardRate();
        vm.warp(block.timestamp + 12 hours);
        _stake(bob, 1_000e18);
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(staking.earned(alice), rate * 12 hours + rate * 12 hours / 2, 2);
        assertApproxEqAbs(staking.earned(bob), rate * 12 hours / 2, 2);
    }

    /// SPEC Step 4: a stake placed just before funding earns only for the time it stays staked.
    function test_stake_just_before_funding_earns_only_while_staked() public {
        _stake(alice, 1_000e18);
        _fund(1 ether);
        vm.warp(block.timestamp + 23 hours); // the ETH sat here all day, unstreamed
        _stake(bob, 1_000e18); // one block before the funding
        staking.notifyRewards();
        uint256 rate = staking.rewardRate();
        vm.warp(block.timestamp + 1);
        vm.prank(bob);
        staking.withdraw(1_000e18); // one second later
        vm.warp(block.timestamp + 24 hours);
        assertApproxEqAbs(staking.earned(bob), rate / 2, 1);
        assertApproxEqAbs(staking.earned(alice), rate * 24 hours - rate / 2, 2);
    }

    function test_a_day_with_nobody_staked_rolls_over() public {
        _fund(1 ether);
        staking.notifyRewards(); // nobody staked
        uint256 first = staking.lastFundingAmount();
        vm.warp(block.timestamp + 24 hours);
        _stake(alice, 1_000e18);
        staking.notifyRewards(); // the whole first day streams again
        assertEq(staking.lastFundingAmount(), first);
        vm.warp(block.timestamp + 24 hours);
        assertApproxEqAbs(staking.earned(alice), first, 1);
    }

    function test_part_of_a_day_with_nobody_staked_rolls_over() public {
        _fund(1 ether);
        staking.notifyRewards();
        uint256 rate = staking.rewardRate();
        vm.warp(block.timestamp + 12 hours); // half the day, nobody staked
        _stake(alice, 1_000e18);
        vm.warp(block.timestamp + 12 hours);
        assertApproxEqAbs(staking.earned(alice), rate * 12 hours, 1);
        staking.notifyRewards();
        assertApproxEqAbs(staking.lastFundingAmount(), 1 ether - rate * 12 hours, 86_400);
    }

    function test_new_tax_eth_joins_the_next_funding() public {
        _stake(alice, 1_000e18);
        _fund(1 ether);
        staking.notifyRewards();
        _fund(2 ether); // arrives during the stream
        vm.warp(block.timestamp + 24 hours);
        uint256 owed = staking.earned(alice);
        staking.notifyRewards();
        assertApproxEqAbs(staking.lastFundingAmount(), 3 ether - owed, 86_400);
    }

    function test_rewards_never_expire() public {
        _stake(alice, 1_000e18);
        _fund(1 ether);
        staking.notifyRewards();
        vm.warp(block.timestamp + 365 days);
        uint256 owed = staking.earned(alice);
        assertGt(owed, 0);
        uint256 before = alice.balance;
        vm.prank(alice);
        assertEq(staking.claim(), owed);
        assertEq(alice.balance - before, owed);
        vm.prank(alice);
        vm.expectRevert(Staking.NothingToClaim.selector);
        staking.claim();
    }

    function test_unstaking_keeps_earned_rewards() public {
        _stake(alice, 1_000e18);
        _fund(1 ether);
        staking.notifyRewards();
        vm.warp(block.timestamp + 12 hours);
        vm.prank(alice);
        staking.withdraw(1_000e18);
        uint256 owed = staking.earned(alice);
        vm.warp(block.timestamp + 12 hours);
        assertEq(staking.earned(alice), owed); // nothing accrues while unstaked
        vm.prank(alice);
        assertEq(staking.claim(), owed);
    }

    function test_accounting_totals() public {
        _stake(alice, 1_000e18);
        _fund(1 ether);
        staking.notifyRewards();
        vm.warp(block.timestamp + 24 hours);
        vm.prank(alice);
        uint256 paid = staking.claim();
        assertEq(staking.totalPaid(), paid);
        assertGe(staking.totalAllocated(), paid);
        assertEq(staking.totalFunded(), _streamed(1 ether));
        assertGe(address(staking).balance, staking.totalAllocated() - staking.totalPaid());
    }

    /// totalFunded is the ETH put into reward streams, each wei counted once (27 September 2026).
    /// Half of day 1 streams while nothing is staked; that half rolls into day 2 and streams again
    /// (unchanged: the funding is everything not owed), but it is not counted again. totalFunded is
    /// then what stakers were credited plus what streams now: the 1.5 ETH received, less only the
    /// under-86,400-wei rounding this funding leaves for the next.
    function test_totalFunded_counts_rolled_over_eth_once() public {
        _fund(1 ether);
        staking.notifyRewards();
        assertEq(staking.totalFunded(), _streamed(1 ether));
        vm.warp(block.timestamp + 12 hours); // nobody staked for half the day
        _stake(alice, 1_000e18);
        vm.warp(block.timestamp + 12 hours);
        _fund(0.5 ether);
        staking.notifyRewards();

        uint256 pool = address(staking).balance - (staking.totalAllocated() - staking.totalPaid());
        assertEq(staking.lastFundingAmount(), _streamed(pool), "the funding itself is unchanged");
        assertGt(pool, 0.5 ether + 0.4 ether, "about half of day 1 rolled over into it");
        assertEq(staking.totalFunded(), staking.totalAllocated() + staking.lastFundingAmount());
        assertEq(staking.totalFunded(), 1.5 ether - pool % 86_400);
        assertLe(staking.totalFunded(), 1.5 ether, "never more than the ETH received");
    }

    function testFuzz_payouts_never_exceed_what_arrived(
        uint96 fundA,
        uint96 fundB,
        uint64 stakeA,
        uint64 stakeB,
        uint32 gap
    ) public {
        uint256 a = bound(fundA, 0, 1_000 ether);
        uint256 b = bound(fundB, 0, 1_000 ether);
        uint256 sa = bound(stakeA, 1, 10_000_000e18);
        uint256 sb = bound(stakeB, 1, 10_000_000e18);
        uint256 dt = bound(gap, 1, 3 days);
        _stake(alice, sa);
        _fund(a);
        staking.notifyRewards();
        vm.warp(block.timestamp + dt);
        _stake(bob, sb);
        _fund(b);
        vm.warp(block.timestamp + 24 hours);
        staking.notifyRewards();
        vm.warp(block.timestamp + 24 hours);
        uint256 paid;
        vm.prank(alice);
        try staking.claim() returns (uint256 x) {
            paid += x;
        } catch {}
        vm.prank(bob);
        try staking.claim() returns (uint256 x) {
            paid += x;
        } catch {}
        assertLe(paid, a + b);
        assertEq(address(staking).balance, a + b - paid);
        assertLe(staking.totalPaid(), staking.totalAllocated());
        assertLe(staking.totalAllocated(), staking.totalFunded());
        assertLe(staking.totalFunded(), a + b);
    }
}
