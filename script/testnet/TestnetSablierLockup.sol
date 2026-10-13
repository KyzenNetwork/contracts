// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ISablierLockup} from "../interfaces/ISablierLockup.sol";

/// @title Testnet stand-in for Sablier Lockup v4.0 (SPEC 3.1: team vesting)
/// @notice Robinhood Chain testnet (46630) has no Sablier deployment, so the testnet launch
/// streams to this instead. It models the one stream shape the launch creates, with Sablier's own
/// rules for it: the funds come from `msg.sender`, `params.sender` is recorded as the stream's
/// sender, nothing unlocks before the cliff, and from the cliff the amount streams linearly to
/// the end time (Lockup v2.0 and later stream from the cliff, not from the start). Only the
/// recipient withdraws. Never deployed on mainnet (4663), where the launch uses Sablier's
/// deployment (RobinhoodChain.SABLIER_LOCKUP).
contract TestnetSablierLockup is ISablierLockup {
    using SafeERC20 for IERC20;

    struct Stream {
        address sender;
        address recipient;
        IERC20 token;
        uint128 deposited;
        uint128 withdrawn;
        uint40 start;
        uint40 cliff;
        uint40 end;
        bool cancelable;
        bool transferable;
    }

    uint256 public nextStreamId = 1;
    mapping(uint256 => Stream) private _streams;

    event CreateLockupLinearStream(uint256 indexed streamId, address indexed sender, address indexed recipient);
    event WithdrawFromLockupStream(uint256 indexed streamId, address indexed to, uint128 amount);

    error Unsupported();
    error BadStream();
    error NotRecipient();
    error Overdraw(uint128 requested, uint128 withdrawable);

    /// The launch's shape only: no start or cliff unlock, one-second granularity, a cliff strictly
    /// between start and end. Anything else reverts rather than being modelled loosely.
    function createWithTimestampsLL(
        CreateWithTimestamps calldata params,
        UnlockAmounts calldata unlockAmounts,
        uint40 granularity,
        uint40 cliffTime
    ) external payable returns (uint256 streamId) {
        if (msg.value != 0 || unlockAmounts.start != 0 || unlockAmounts.cliff != 0 || granularity != 0) {
            revert Unsupported();
        }
        if (
            params.sender == address(0) || params.recipient == address(0) || params.depositAmount == 0
                || params.timestamps.start >= params.timestamps.end || cliffTime <= params.timestamps.start
                || cliffTime >= params.timestamps.end
        ) revert BadStream();
        streamId = nextStreamId++;
        _streams[streamId] = Stream({
            sender: params.sender,
            recipient: params.recipient,
            token: params.token,
            deposited: params.depositAmount,
            withdrawn: 0,
            start: params.timestamps.start,
            cliff: cliffTime,
            end: params.timestamps.end,
            cancelable: params.cancelable,
            transferable: params.transferable
        });
        params.token.safeTransferFrom(msg.sender, address(this), params.depositAmount);
        emit CreateLockupLinearStream(streamId, params.sender, params.recipient);
    }

    /// The recipient takes up to what has streamed and not yet been withdrawn.
    function withdraw(uint256 streamId, address to, uint128 amount) external {
        Stream storage s = _streams[streamId];
        if (msg.sender != s.recipient) revert NotRecipient();
        uint128 withdrawable = streamedAmountOf(streamId) - s.withdrawn;
        if (amount > withdrawable) revert Overdraw(amount, withdrawable);
        s.withdrawn += amount;
        s.token.safeTransfer(to, amount);
        emit WithdrawFromLockupStream(streamId, to, amount);
    }

    function streamedAmountOf(uint256 streamId) public view returns (uint128) {
        Stream memory s = _streams[streamId];
        if (block.timestamp < s.cliff) return 0;
        if (block.timestamp >= s.end) return s.deposited;
        // Below `deposited`, which is a uint128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(uint256(s.deposited) * (block.timestamp - s.cliff) / (s.end - s.cliff));
    }

    function getRecipient(uint256 streamId) external view returns (address) {
        return _streams[streamId].recipient;
    }

    function getSender(uint256 streamId) external view returns (address) {
        return _streams[streamId].sender;
    }

    function getDepositedAmount(uint256 streamId) external view returns (uint128) {
        return _streams[streamId].deposited;
    }

    function getCliffTime(uint256 streamId) external view returns (uint40) {
        return _streams[streamId].cliff;
    }

    function getEndTime(uint256 streamId) external view returns (uint40) {
        return _streams[streamId].end;
    }

    function isCancelable(uint256 streamId) external view returns (bool) {
        return _streams[streamId].cancelable;
    }

    function isTransferable(uint256 streamId) external view returns (bool) {
        return _streams[streamId].transferable;
    }
}
