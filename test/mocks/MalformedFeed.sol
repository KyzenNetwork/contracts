// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// A Chainlink-shaped feed whose latestRoundData can answer with too few bytes, answer with
/// nothing, or burn all the gas it is given, the way a retired or upgraded aggregator might.
contract MalformedFeed {
    enum Mode {
        Normal,
        ShortAnswer,
        AnswerNothing,
        BurnGas
    }

    uint8 public immutable decimals;
    Mode public mode;
    int256 public answer;
    uint256 public updatedAt;

    constructor(uint8 decimals_, int256 answer_) {
        decimals = decimals_;
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function set(int256 answer_, uint256 updatedAt_) external {
        answer = answer_;
        updatedAt = updatedAt_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        if (mode == Mode.BurnGas) {
            while (true) {}
        }
        if (mode == Mode.AnswerNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        if (mode == Mode.ShortAnswer) {
            // 64 bytes: two of the five words a real answer holds.
            assembly ("memory-safe") {
                let ptr := mload(0x40)
                mstore(ptr, 1)
                mstore(add(ptr, 0x20), 100000000)
                return(ptr, 0x40)
            }
        }
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
