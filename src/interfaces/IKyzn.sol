// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// $KYZN as the Reserve and the Gateway settlement contract use it: any holder burns its own tokens.
interface IKyzn is IERC20 {
    function burn(uint256 amount) external;
    /// The Uniswap v2 $KYZN/WETH pair.
    function pair() external view returns (address);
    /// The Staking contract; the token's owner can change it until renouncing.
    function staking() external view returns (address);
}
