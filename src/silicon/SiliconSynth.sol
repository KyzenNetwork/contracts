// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ISiliconSynth} from "./interfaces/ISiliconSynth.sol";

/// @title Kyzen Network Silicon synth (SPEC 3.5)
/// @notice One market's synthetic token, 18 decimals: "Kyzen Network H100-HR" (kH100) and so on.
/// Only the vault mints and burns, so every unit in circulation is owed to the vault by a
/// position, by an auction, or is recorded as the market's bad debt.
contract SiliconSynth is ERC20, ISiliconSynth {
    /// The SiliconVault that mints and burns this synth, fixed at deployment.
    address public immutable vault;

    /// The vault address is zero.
    error ZeroAddress();
    /// The caller is not the vault.
    error NotVault();

    modifier onlyVault() {
        _checkVault();
        _;
    }

    /// Deploy before addMarket: the vault checks that the synth names it.
    constructor(string memory name_, string memory symbol_, address vault_) ERC20(name_, symbol_) {
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
    }

    /// Mints `amount` to `to`: a position's mint, or fees to the fee router.
    function mint(address to, uint256 amount) external onlyVault {
        _mint(to, amount);
    }

    /// Burns `amount` from `from`: a repayment, a bid or a bad-debt cover. The vault only ever
    /// burns from the account that called it.
    function burn(address from, uint256 amount) external onlyVault {
        _burn(from, amount);
    }

    function _checkVault() private view {
        if (msg.sender != vault) revert NotVault();
    }
}
