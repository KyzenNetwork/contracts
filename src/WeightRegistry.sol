// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IRotationState} from "./interfaces/IRotationState.sol";

/// @title Kyzen Network Scheduler weight registry (SPEC 3.4)
/// @notice The Scheduler publisher (the owner) records each rotation: five stage weights
/// (design, memory, fab, equipment, power), the memo hash and link, and when it executes.
contract WeightRegistry is Ownable2Step, IRotationState {
    uint256 public constant STAGES = 5;
    uint256 public constant MAX_WEIGHT_BPS = 5_000;
    uint256 public constant TOTAL_BPS = 10_000;
    /// SPEC 3.4's monthly cadence: a rotation may not be scheduled more than 31 days out.
    uint256 public constant MAX_HORIZON = 31 days;

    struct Entry {
        uint16[5] weights;
        bytes32 memoHash;
        string memoURI;
        uint64 executesAt;
        uint64 publishedAt;
    }

    Entry[] private _entries;

    event Rotation(uint256 indexed n, uint16[5] weights, bytes32 memoHash, string memoURI, uint64 executesAt);

    error WeightAboveCap(uint256 stage);
    error DesignAndPowerAboveCap();
    error WeightsDoNotSum();
    error EmptyMemo();
    error ExecutesInPast();
    error ExecutesTooLate();
    error ExecutesBeforePrevious();
    error NoRotation();

    constructor() Ownable(msg.sender) {}

    /// Each weight at most 5,000 bps (the 50% stage cap); the five sum to 10,000. Power has no
    /// stage of its own and is held in design (SPEC 3.2), so design and power together may not
    /// exceed 5,000 bps either. Execution is at most 31 days out (SPEC 3.4's monthly cadence),
    /// so a mistaken far-future date cannot lock out every sooner rotation the way the
    /// non-decreasing executesAt rule otherwise would.
    function publish(uint16[5] calldata weights, bytes32 memoHash, string calldata memoURI, uint64 executesAt)
        external
        onlyOwner
        returns (uint256 n)
    {
        uint256 sum;
        for (uint256 i; i < STAGES; ++i) {
            if (weights[i] > MAX_WEIGHT_BPS) revert WeightAboveCap(i);
            sum += weights[i];
        }
        if (uint256(weights[0]) + weights[4] > MAX_WEIGHT_BPS) revert DesignAndPowerAboveCap();
        if (sum != TOTAL_BPS) revert WeightsDoNotSum();
        if (memoHash == bytes32(0) || bytes(memoURI).length == 0) revert EmptyMemo();
        if (executesAt < block.timestamp) revert ExecutesInPast();
        if (executesAt > block.timestamp + MAX_HORIZON) revert ExecutesTooLate();
        n = _entries.length;
        if (n != 0 && executesAt < _entries[n - 1].executesAt) revert ExecutesBeforePrevious();
        _entries.push(
            Entry({
                weights: weights,
                memoHash: memoHash,
                memoURI: memoURI,
                executesAt: executesAt,
                publishedAt: uint64(block.timestamp)
            })
        );
        emit Rotation(n, weights, memoHash, memoURI, executesAt);
    }

    function rotationCount() external view returns (uint256) {
        return _entries.length;
    }

    function rotation(uint256 n) external view returns (Entry memory) {
        return _entries[n];
    }

    function latest() external view returns (Entry memory) {
        if (_entries.length == 0) revert NoRotation();
        return _entries[_entries.length - 1];
    }

    /// True once the first rotation's execution time has passed; the Reserve may sell from then on.
    function hasExecuted() external view returns (bool) {
        return _entries.length != 0 && block.timestamp >= _entries[0].executesAt;
    }
}
