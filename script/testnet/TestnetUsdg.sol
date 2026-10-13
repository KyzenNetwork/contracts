// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @title Testnet stand-in for USDG (SPEC 3.5)
/// @notice Robinhood Chain testnet (46630) has no USDG, so the testnet Silicon vault takes this as
/// its second collateral. A 6-decimal ERC-20, like USDG on mainnet. The owner mints, to fund test
/// positions; minting is owner-only, since the testnet is public. Never deployed on mainnet (4663).
contract TestnetUsdg is ERC20, Ownable {
    uint8 private constant DECIMALS = 6;

    constructor() ERC20("USDG testnet stand-in", "USDG") Ownable(msg.sender) {}

    function decimals() public pure override returns (uint8) {
        return DECIMALS;
    }

    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
}
