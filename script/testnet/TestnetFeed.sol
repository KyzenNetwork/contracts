// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Testnet stand-in for a Chainlink price feed (SPEC 3.2a)
/// @notice Robinhood Chain testnet (46630) has no Chainlink feeds for the stock tokens or ETH/USD,
/// so the testnet deployment reads these instead. 8 decimals, like the mainnet feeds. The owner
/// sets the answer and its update time; each set is a new round, kept so that getRoundData
/// answers for it as Chainlink's does (a StockIndexFeed walks the rounds since its checked one).
/// Nothing updates it on its own: after 24 hours without a set, the Reserve and Staking treat the
/// price as stale. Owner-only, since the testnet is public. Never deployed on mainnet (4663).
contract TestnetFeed is Ownable {
    uint8 private constant DECIMALS = 8;

    /// One round as set: its answer and update time.
    struct Round {
        int256 answer;
        uint256 updatedAt;
    }

    string public description;
    uint80 public roundId;
    int256 public answer;
    uint256 public updatedAt;
    /// Every round set so far, from 1 to roundId.
    mapping(uint80 roundId => Round) private _rounds;

    event AnswerSet(uint80 indexed roundId, int256 answer, uint256 updatedAt);

    /// No round has this id: 0, or past the latest.
    error UnknownRound(uint80 roundId);

    /// Starts at round 1 with `answer_`, updated now.
    constructor(string memory description_, int256 answer_) Ownable(msg.sender) {
        description = description_;
        _set(answer_, block.timestamp);
    }

    function decimals() external pure returns (uint8) {
        return DECIMALS;
    }

    function set(int256 answer_, uint256 updatedAt_) external onlyOwner {
        _set(answer_, updatedAt_);
    }

    /// Chainlink's AggregatorV3 shape: startedAt equals updatedAt, answeredInRound equals roundId.
    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (roundId, answer, updatedAt, updatedAt, roundId);
    }

    /// Round `roundId_` as it was set, in the same shape as latestRoundData. Reverts UnknownRound
    /// for round 0 and any round past the latest, as Chainlink reverts for a round it has no data
    /// for.
    function getRoundData(uint80 roundId_) external view returns (uint80, int256, uint256, uint256, uint80) {
        if (roundId_ == 0 || roundId_ > roundId) revert UnknownRound(roundId_);
        Round storage r = _rounds[roundId_];
        return (roundId_, r.answer, r.updatedAt, r.updatedAt, roundId_);
    }

    function _set(int256 answer_, uint256 updatedAt_) private {
        uint80 round = roundId + 1;
        roundId = round;
        answer = answer_;
        updatedAt = updatedAt_;
        _rounds[round] = Round({answer: answer_, updatedAt: updatedAt_});
        emit AnswerSet(round, answer_, updatedAt_);
    }
}
