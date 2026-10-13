// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {Staking} from "../../src/Staking.sol";
import {Fixture} from "../utils/Fixture.sol";

/// Random stakes, unstakes, claims, compound claims, tax ETH arrivals, fundings and time.
contract StakingHandler is Test {
    KyznToken internal token;
    Staking internal staking;
    address[3] internal actors;

    uint256 public ghostReceived; // ETH sent to Staking
    uint256 public receivedAtFunding; // ghostReceived at the last notifyRewards
    /// Set if a funding ever lowered totalFunded, which only rises.
    bool public fundedDecreased;
    uint256 public compounds;

    constructor(KyznToken token_, Staking staking_) {
        token = token_;
        staking = staking_;
        actors = [makeAddr("staker1"), makeAddr("staker2"), makeAddr("staker3")];
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function stake(uint256 who, uint256 amount) external {
        address a = actors[who % 3];
        uint256 balance = token.balanceOf(a);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        vm.startPrank(a);
        token.approve(address(staking), amount);
        staking.stake(amount);
        vm.stopPrank();
    }

    function withdraw(uint256 who, uint256 amount) external {
        address a = actors[who % 3];
        uint256 staked = staking.stakedOf(a);
        if (staked == 0) return;
        amount = bound(amount, 1, staked);
        vm.prank(a);
        staking.withdraw(amount);
    }

    function claim(uint256 who) external {
        address a = actors[who % 3];
        if (staking.earned(a) == 0) return;
        vm.prank(a);
        staking.claim();
    }

    /// Claims rewards as $KYZN bought tax-free and added to the stake.
    function compound(uint256 who) external {
        address a = actors[who % 3];
        if (staking.earned(a) == 0) return;
        vm.prank(a);
        try staking.claimCompound(0) {
            ++compounds;
        } catch {}
    }

    function fund(uint256 amount) external {
        amount = bound(amount, 0, 10 ether);
        // As the token's tax split sends it: Staking takes ETH from the token only.
        vm.deal(address(token), address(token).balance + amount);
        vm.prank(address(token));
        (bool ok,) = address(staking).call{value: amount}("");
        require(ok, "fund");
        ghostReceived += amount;
    }

    function notify() external {
        if (block.timestamp < staking.nextFundingAt()) return;
        uint256 fundedBefore = staking.totalFunded();
        staking.notifyRewards();
        receivedAtFunding = ghostReceived;
        if (staking.totalFunded() < fundedBefore) fundedDecreased = true;
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
    }
}

/// SPEC Step 4 staking invariants: paid plus owed never exceeds funded; staked tokens are
/// all held; every wei that arrived is either still held or was paid out.
contract StakingInvariantTest is Fixture {
    StakingHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new StakingHandler(token, staking);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actor(i), 10_000_000e18);
        }
        _launch();
        token.removeMaxWallet();
        targetContract(address(handler));
    }

    function invariant_paid_never_exceeds_allocated() public view {
        assertLe(staking.totalPaid(), staking.totalAllocated());
        assertLe(staking.totalAllocated(), handler.ghostReceived());
    }

    function invariant_owed_is_covered() public view {
        assertGe(address(staking).balance, staking.totalAllocated() - staking.totalPaid());
        uint256 claimable;
        for (uint256 i; i < 3; ++i) {
            claimable += staking.earned(handler.actor(i));
        }
        assertLe(claimable, address(staking).balance);
    }

    /// totalFunded counts each wei once (27 September 2026): it covers everything credited to
    /// stakers, never exceeds the ETH received, and trails the ETH received up to the last funding
    /// by less than 86,400 wei, the rounding a funding can leave for the next.
    function invariant_funded_never_decreases() public view {
        assertFalse(handler.fundedDecreased());
    }

    function invariant_funded_counts_each_wei_once() public view {
        assertLe(staking.totalAllocated(), staking.totalFunded());
        assertLe(staking.totalFunded(), handler.ghostReceived());
        assertLt(handler.receivedAtFunding(), staking.totalFunded() + 86_400);
    }

    function invariant_eth_is_conserved() public view {
        assertEq(handler.ghostReceived(), address(staking).balance + staking.totalPaid());
    }

    function invariant_stake_is_fully_held() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += staking.stakedOf(handler.actor(i));
        }
        assertEq(sum, staking.totalStaked());
        assertEq(token.balanceOf(address(staking)), staking.totalStaked());
    }

    /// "Pending" is the ETH the reward stream would allocate right now but has not yet been
    /// checkpointed into totalAllocated: the same computation Staking._accrued() does privately
    /// (rewardRate accrued from lastUpdateTime to min(now, periodFinish), scaled by totalStaked),
    /// reproduced here from public state (periodFinish, lastUpdateTime, rewardRate, totalStaked)
    /// with the same PRECISION (1e36) and the same ceiling rounding Staking.sol uses so that
    /// allocations always cover what stakers can claim (Staking.sol, read-only for this task).
    function _pending() internal view returns (uint256) {
        uint256 end = block.timestamp < staking.periodFinish() ? block.timestamp : staking.periodFinish();
        uint256 totalStaked = staking.totalStaked();
        if (totalStaked == 0 || end <= staking.lastUpdateTime()) return 0;
        uint256 increment = Math.mulDiv((end - staking.lastUpdateTime()) * staking.rewardRate(), 1e36, totalStaked);
        return Math.mulDiv(increment, totalStaked, 1e36, Math.Rounding.Ceil);
    }

    /// The strong solvency invariant (review item 10): for every account, what it could claim
    /// right now never exceeds the true allocated total -- the checkpointed totalAllocated plus
    /// the pending accrual since the last checkpoint, minus what has already been paid -- and
    /// that true total never exceeds the ETH the contract actually holds.
    function invariant_claimable_never_exceeds_true_allocation_within_balance() public view {
        uint256 trueAllocatedLessPaid = staking.totalAllocated() + _pending() - staking.totalPaid();
        assertLe(trueAllocatedLessPaid, address(staking).balance);
        for (uint256 i; i < 3; ++i) {
            assertLe(staking.earned(handler.actor(i)), trueAllocatedLessPaid);
        }
    }
}
