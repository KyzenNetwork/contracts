// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {WeightRegistry} from "../src/WeightRegistry.sol";
import {IRotationState} from "../src/interfaces/IRotationState.sol";

/// Scheduler weights on-chain (SPEC 3.4): each stage at most 50%, five sum to 100%.
contract WeightRegistryTest is Test {
    uint256 internal constant MONDAY_1400 = 1_790_604_000;
    WeightRegistry internal registry;
    bytes32 internal constant MEMO = keccak256("memo 1");
    string internal constant URI = "https://kyzen.network/scheduler/memo-1";

    function setUp() public {
        vm.warp(MONDAY_1400);
        registry = new WeightRegistry();
    }

    function _weights(uint16 a, uint16 b, uint16 c, uint16 d, uint16 e) internal pure returns (uint16[5] memory w) {
        w = [a, b, c, d, e];
    }

    function test_publish_records_the_rotation() public {
        uint16[5] memory w = _weights(4_000, 2_000, 2_000, 1_000, 1_000);
        uint64 at = uint64(block.timestamp + 30 days);
        vm.expectEmit(address(registry));
        emit WeightRegistry.Rotation(0, w, MEMO, URI, at);
        assertEq(registry.publish(w, MEMO, URI, at), 0);
        assertEq(registry.rotationCount(), 1);
        WeightRegistry.Entry memory e = registry.latest();
        assertEq(e.weights[0], 4_000);
        assertEq(e.weights[4], 1_000);
        assertEq(e.memoHash, MEMO);
        assertEq(e.memoURI, URI);
        assertEq(e.executesAt, at);
        assertEq(e.publishedAt, block.timestamp);
    }

    function test_weight_above_50_percent_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(WeightRegistry.WeightAboveCap.selector, 1));
        registry.publish(_weights(2_000, 5_001, 1_000, 1_000, 999), MEMO, URI, uint64(block.timestamp));
    }

    function test_50_percent_is_allowed() public {
        registry.publish(_weights(5_000, 5_000, 0, 0, 0), MEMO, URI, uint64(block.timestamp));
        assertEq(registry.rotationCount(), 1);
    }

    function test_weights_must_sum_to_100_percent() public {
        vm.expectRevert(WeightRegistry.WeightsDoNotSum.selector);
        registry.publish(_weights(4_000, 2_000, 2_000, 1_000, 999), MEMO, URI, uint64(block.timestamp));
    }

    function test_memo_is_required() public {
        uint16[5] memory w = _weights(4_000, 2_000, 2_000, 1_000, 1_000);
        vm.expectRevert(WeightRegistry.EmptyMemo.selector);
        registry.publish(w, bytes32(0), URI, uint64(block.timestamp));
        vm.expectRevert(WeightRegistry.EmptyMemo.selector);
        registry.publish(w, MEMO, "", uint64(block.timestamp));
    }

    function test_execution_time_rules() public {
        uint16[5] memory w = _weights(4_000, 2_000, 2_000, 1_000, 1_000);
        vm.expectRevert(WeightRegistry.ExecutesInPast.selector);
        registry.publish(w, MEMO, URI, uint64(block.timestamp - 1));
        registry.publish(w, MEMO, URI, uint64(block.timestamp + 30 days));
        vm.expectRevert(WeightRegistry.ExecutesBeforePrevious.selector);
        registry.publish(w, MEMO, URI, uint64(block.timestamp + 29 days));
        // Was +60 days: now beyond the 31-day horizon (SPEC 3.4 monthly cadence), so this is
        // changed to +30 days, equal to the previous entry, showing an equal consecutive
        // executesAt is accepted (the rule only forbids going backwards).
        registry.publish(w, MEMO, URI, uint64(block.timestamp + 30 days));
        assertEq(registry.rotationCount(), 2);
        assertEq(registry.rotation(0).executesAt, block.timestamp + 30 days);
        assertEq(registry.rotation(1).executesAt, block.timestamp + 30 days);
    }

    function test_hasExecuted_follows_the_first_rotation() public {
        assertFalse(registry.hasExecuted());
        registry.publish(_weights(4_000, 2_000, 2_000, 1_000, 1_000), MEMO, URI, uint64(block.timestamp + 30 days));
        assertFalse(registry.hasExecuted());
        vm.warp(block.timestamp + 30 days - 1);
        assertFalse(registry.hasExecuted());
        vm.warp(block.timestamp + 1);
        assertTrue(registry.hasExecuted());
    }

    function test_hasExecuted_keys_off_the_first_rotation() public {
        uint256 start = block.timestamp;
        uint16[5] memory w = _weights(4_000, 2_000, 2_000, 1_000, 1_000);
        registry.publish(w, MEMO, URI, uint64(start + 30 days));
        // Was +60 days: now beyond the 31-day horizon (SPEC 3.4 monthly cadence) measured from
        // `start`, since both publishes happen at the same block.timestamp. +31 days is the
        // latest allowed and still later than the first rotation, so the test still has two
        // distinct rotations to tell "first" from "latest".
        registry.publish(w, MEMO, URI, uint64(start + 31 days));
        vm.warp(start + 30 days - 1);
        assertFalse(registry.hasExecuted());
        vm.warp(start + 30 days);
        assertTrue(registry.hasExecuted());
    }

    function test_latest_without_rotation_reverts() public {
        vm.expectRevert(WeightRegistry.NoRotation.selector);
        registry.latest();
    }

    function test_publish_is_owner_only() public {
        address alice = makeAddr("alice");
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        registry.publish(_weights(4_000, 2_000, 2_000, 1_000, 1_000), MEMO, URI, uint64(block.timestamp));
    }

    /// b (memory), c (fab) and d (equipment) are fuzzed directly; design (a) and power (e) split
    /// whatever is left, so their combined weight always respects the new design+power cap
    /// (previously this derived power alone as the remainder, which could pair with a large
    /// design to sum past 5,000 -- see test_publish_reverts_when_design_plus_power_exceeds_the_cap).
    function testFuzz_accepted_weights_respect_the_cap(uint16 a, uint16 b, uint16 c, uint16 d) public {
        b = uint16(bound(b, 0, 5_000));
        c = uint16(bound(c, 0, 5_000));
        d = uint16(bound(d, 0, 5_000));
        vm.assume(uint256(b) + c + d <= 10_000);
        uint256 designPlusPower = 10_000 - uint256(b) - c - d;
        vm.assume(designPlusPower <= 5_000);
        a = uint16(bound(a, 0, designPlusPower));
        uint16 e = uint16(designPlusPower - a);
        registry.publish(_weights(a, b, c, d, e), MEMO, URI, uint64(block.timestamp));
        uint16[5] memory w = registry.latest().weights;
        uint256 sum;
        for (uint256 i; i < 5; ++i) {
            assertLe(w[i], 5_000);
            sum += w[i];
        }
        assertLe(uint256(w[0]) + w[4], 5_000);
        assertEq(sum, 10_000);
    }

    function test_max_horizon_is_31_days() public view {
        assertEq(registry.MAX_HORIZON(), 31 days);
    }

    function test_executesAt_may_be_up_to_31_days_out() public {
        uint16[5] memory w = _weights(4_000, 2_000, 2_000, 1_000, 1_000);
        registry.publish(w, MEMO, URI, uint64(block.timestamp + registry.MAX_HORIZON()));
        assertEq(registry.rotationCount(), 1);
    }

    /// Ported from the reviewer's probe test_probe_far_future_first_rotation_locks_the_registry:
    /// a typo'd executesAt 100 years out used to be accepted, and then every later, sane publish
    /// reverted with ExecutesBeforePrevious forever, because executesAt can never decrease
    /// (SPEC 3.4's monthly cadence bounds how far a rotation may be scheduled). The publish must
    /// now revert immediately, so the typo is never recorded and a normal-cadence rotation still
    /// publishes right after.
    function test_publish_reverts_when_executesAt_is_beyond_the_horizon() public {
        uint16[5] memory w = _weights(4_000, 2_000, 2_000, 1_000, 1_000);
        vm.expectRevert(WeightRegistry.ExecutesTooLate.selector);
        registry.publish(w, keccak256("m"), "uri", uint64(block.timestamp + 100 * 365 days));
        assertEq(registry.rotationCount(), 0);
        registry.publish(w, keccak256("m2"), "uri2", uint64(block.timestamp + 30 days));
        assertEq(registry.rotationCount(), 1);
        assertFalse(registry.hasExecuted());
    }

    /// Ported from the reviewer's probe test_probe_design_plus_power_can_exceed_the_cap: power
    /// has no stage of its own (SPEC 3.2, "Power: held in Design"), so checking each of the five
    /// weights against the 50% cap independently let design and power add up to 100% between
    /// them. The combined weight must now be rejected.
    function test_publish_reverts_when_design_plus_power_exceeds_the_cap() public {
        uint16[5] memory w = _weights(5_000, 0, 0, 0, 5_000);
        vm.expectRevert(WeightRegistry.DesignAndPowerAboveCap.selector);
        registry.publish(w, MEMO, URI, uint64(block.timestamp));
        assertEq(registry.rotationCount(), 0);
    }

    function test_design_plus_power_at_the_cap_is_allowed() public {
        uint16[5] memory w = _weights(2_500, 2_500, 2_500, 0, 2_500); // design 2,500 + power 2,500 = 5,000
        registry.publish(w, MEMO, URI, uint64(block.timestamp));
        WeightRegistry.Entry memory e = registry.latest();
        assertEq(e.weights[0] + e.weights[4], 5_000);
    }

    /// Compile-time proof of requirement 1: this assignment only type-checks if WeightRegistry
    /// declares `is IRotationState`. Before that declaration, the Reserve held it as
    /// IRotationState only through an address cast that skips this check (progress.md, Task 3).
    function test_registry_is_an_IRotationState() public view {
        IRotationState r = registry;
        assertFalse(r.hasExecuted());
    }
}
