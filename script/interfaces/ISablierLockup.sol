// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// Sablier Lockup v4.0 (SPEC 3.1: team vesting), the subset the launch script uses: creating a
/// linear stream with explicit start/cliff/end timestamps, and reading it back. Verified against
/// the npm package "sablier slash lockup", version 4.0.0 (fetched with `npm pack`): the structs and `createWithTimestampsLL` signature are copied verbatim from
/// `src/interfaces/ISablierLockupLinear.sol`; the view signatures below match
/// `src/interfaces/ISablierLockupState.sol` (`getCliffTime`, `getDepositedAmount`, `getEndTime`,
/// `isCancelable`, `isTransferable`) and the top-level `src/interfaces/ISablierLockup.sol`
/// (`getRecipient`, `streamedAmountOf`), which is not itself importable here: it pulls in the
/// "sablier slash evm-utils" package and the other Lockup models, none of which Kyzen Network
/// depends on. The deployed Lockup contract on Robinhood Chain (4663) is
/// `0x548129a58bC230549DF7F9e33f27E77F6779ff0f` (Sablier's deployment list; the deployed code
/// contains the `createWithDurationsLL` selector `0x7b4dae9e`).
interface ISablierLockup {
    struct Timestamps {
        uint40 start;
        uint40 end;
    }

    struct CreateWithTimestamps {
        address sender;
        address recipient;
        uint128 depositAmount;
        IERC20 token;
        bool cancelable;
        bool transferable;
        Timestamps timestamps;
        string shape;
    }

    struct UnlockAmounts {
        uint128 start;
        uint128 cliff;
    }

    /// Creates a stream with the provided start and end time, funded by `msg.sender`.
    /// `granularity` zero means the smallest step is one second; `cliffTime` zero means no cliff.
    function createWithTimestampsLL(
        CreateWithTimestamps calldata params,
        UnlockAmounts calldata unlockAmounts,
        uint40 granularity,
        uint40 cliffTime
    ) external payable returns (uint256 streamId);

    function getRecipient(uint256 streamId) external view returns (address recipient);
    function getSender(uint256 streamId) external view returns (address sender);
    function getDepositedAmount(uint256 streamId) external view returns (uint128 depositedAmount);
    function getCliffTime(uint256 streamId) external view returns (uint40 cliffTime);
    function getEndTime(uint256 streamId) external view returns (uint40 endTime);
    function isCancelable(uint256 streamId) external view returns (bool result);
    function isTransferable(uint256 streamId) external view returns (bool result);
    function streamedAmountOf(uint256 streamId) external view returns (uint128 streamedAmount);
}
