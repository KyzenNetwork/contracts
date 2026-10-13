// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {WeightRegistry} from "../../src/WeightRegistry.sol";

/// Random publishes against the registry it owns: some are a valid rotation, some deliberately
/// break one publish rule (the design+power cap, the 31-day horizon, or a single stage's 50%
/// cap), and time passes between them. `fail_on_revert = false` (foundry.toml) already lets a
/// reverting call through without failing the run; the try/catch here is only for the
/// accepted/rejected counters, matching ReserveHandler's and StakingHandler's style.
contract RegistryHandler is Test {
    WeightRegistry public registry;
    uint256 public accepted;
    uint256 public rejected;

    constructor() {
        registry = new WeightRegistry(); // this handler is msg.sender, so it is the owner
    }

    function publish(uint16 a, uint16 b, uint16 c, uint16 d, uint256 executesIn, uint256 mode) external {
        mode = bound(mode, 0, 3);
        uint16[5] memory w;
        bytes32 memoHash = keccak256(abi.encode(registry.rotationCount(), a, b, c, d, executesIn, mode));

        if (mode == 0) {
            // A valid combination: memory/fab/equipment fuzzed, design and power split the rest.
            b = uint16(bound(b, 0, 5_000));
            c = uint16(bound(c, 0, 5_000));
            d = uint16(bound(d, 0, 5_000));
            if (uint256(b) + c + d > 10_000) return;
            uint256 designPlusPower = 10_000 - uint256(b) - c - d;
            if (designPlusPower > 5_000) return;
            a = uint16(bound(a, 0, designPlusPower));
            uint16 e = uint16(designPlusPower - a);
            w = [a, b, c, d, e];
            executesIn = bound(executesIn, 0, registry.MAX_HORIZON());
        } else if (mode == 1) {
            // Deliberately breaks the design+power cap: power held in design, so 5,000 / 5,000
            // between them is 100%, not 50% (SPEC 3.2).
            w = [uint16(5_000), 0, 0, 0, 5_000];
            executesIn = bound(executesIn, 0, registry.MAX_HORIZON());
        } else if (mode == 2) {
            // Deliberately past the 31-day horizon (SPEC 3.4's monthly cadence).
            w = [uint16(4_000), 2_000, 2_000, 1_000, 1_000];
            executesIn = bound(executesIn, registry.MAX_HORIZON() + 1, registry.MAX_HORIZON() + 365 days);
        } else {
            // Deliberately a single stage over the 50% cap.
            w = [uint16(5_001), 0, 0, 0, 0];
            executesIn = bound(executesIn, 0, registry.MAX_HORIZON());
        }

        uint256 before = registry.rotationCount();
        try registry.publish(w, memoHash, "uri", uint64(block.timestamp + executesIn)) {
            require(registry.rotationCount() == before + 1, "accepted publish did not record an entry");
            ++accepted;
        } catch {
            require(registry.rotationCount() == before, "a reverted publish still recorded an entry");
            ++rejected;
        }
    }

    /// Time passing is what makes the horizon check (relative to a moving `now`) worth fuzzing.
    function warp(uint256 dt) external {
        vm.warp(block.timestamp + bound(dt, 0, 20 days));
    }
}

/// SPEC Step 4 registry invariants (review items 4, 5): every recorded rotation still satisfies
/// every publish rule, and executesAt never decreases across the whole history, not just between
/// two consecutive calls.
contract RegistryInvariantTest is Test {
    RegistryHandler internal handler;

    function setUp() public {
        vm.warp(1_790_604_000); // Monday 28 September 2026, 14:00 UTC, matching the other fixtures
        handler = new RegistryHandler();
        targetContract(address(handler));
    }

    /// The invariant run's own "Reverts: 0" column only reflects the outer handler call, which
    /// always swallows the inner registry.publish() revert -- this directly forces each of the
    /// four modes once, so a real accept and three real rejects are not left to fuzzer luck.
    function test_handler_dispatches_every_mode_to_accept_or_reject() public {
        handler.publish(4_000, 2_000, 2_000, 1_000, 0, 0); // mode 0: a valid rotation
        assertEq(handler.accepted(), 1);
        assertEq(handler.rejected(), 0);
        handler.publish(0, 0, 0, 0, 0, 1); // mode 1: design + power above the cap
        handler.publish(0, 0, 0, 0, 0, 2); // mode 2: past the 31-day horizon
        handler.publish(0, 0, 0, 0, 0, 3); // mode 3: a single stage above the cap
        assertEq(handler.accepted(), 1);
        assertEq(handler.rejected(), 3);
    }

    function invariant_every_entry_satisfies_every_publish_rule() public view {
        WeightRegistry registry = handler.registry();
        uint256 n = registry.rotationCount();
        for (uint256 i; i < n; ++i) {
            WeightRegistry.Entry memory e = registry.rotation(i);
            uint256 sum;
            for (uint256 s; s < 5; ++s) {
                assertLe(e.weights[s], registry.MAX_WEIGHT_BPS());
                sum += e.weights[s];
            }
            assertEq(sum, registry.TOTAL_BPS());
            assertLe(uint256(e.weights[0]) + e.weights[4], registry.MAX_WEIGHT_BPS());
            assertLe(e.executesAt, e.publishedAt + registry.MAX_HORIZON());
            assertGe(e.executesAt, e.publishedAt);
        }
    }

    function invariant_executesAt_never_decreases() public view {
        WeightRegistry registry = handler.registry();
        uint256 n = registry.rotationCount();
        for (uint256 i = 1; i < n; ++i) {
            assertGe(registry.rotation(i).executesAt, registry.rotation(i - 1).executesAt);
        }
    }
}
