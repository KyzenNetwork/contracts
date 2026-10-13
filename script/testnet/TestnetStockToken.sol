// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Testnet stand-in for a Robinhood Stock Token (SPEC 3.2a)
/// @notice Robinhood Chain testnet (46630) has no stock tokens, so the testnet deployment lists
/// this in their place. An 18-decimal ERC-20 with the issuer powers the Reserve must tolerate:
/// pause (every balance change reverts, transfers included), the oracle-pause flag the Reserve
/// and Staking read, and a burn from any holder, the Reserve included; plus mint, to seed pools.
/// Every power is owner-only, since the testnet is public. Never deployed on mainnet (4663).
contract TestnetStockToken is ERC20, Ownable {
    bool public paused;
    bool public oraclePaused;

    event PausedSet(bool paused);
    event OraclePausedSet(bool paused);
    event AdminBurned(address indexed from, uint256 amount);

    error TokenPaused();

    constructor(string memory name_, string memory symbol_) ERC20(name_, symbol_) Ownable(msg.sender) {}

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit PausedSet(value);
    }

    function setOraclePaused(bool value) external onlyOwner {
        oraclePaused = value;
        emit OraclePausedSet(value);
    }

    /// The issuer's burn from any holder (SPEC 3.2a).
    function adminBurn(address from, uint256 amount) external onlyOwner {
        _burn(from, amount);
        emit AdminBurned(from, amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (paused) revert TokenPaused();
        super._update(from, to, value);
    }
}
