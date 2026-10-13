// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// @notice The getters the token reads back from the Reserve, Staking and the Gateway when the owner
/// sets them: a guard against setting a wrong address, not proof of a contract's identity.
interface IProtocolPointers {
    function kyzn() external view returns (address);
    function weth() external view returns (address);
    function reserve() external view returns (address);
    function router() external view returns (address);
}
