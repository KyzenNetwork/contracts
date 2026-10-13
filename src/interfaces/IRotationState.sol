// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// What the Reserve reads from the Scheduler weight registry.
interface IRotationState {
    /// True once the first rotation's execution time has passed.
    function hasExecuted() external view returns (bool);
}
