// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// A Robinhood Stock Token stand-in: 18 decimals, issuer pause and oracle-pause flags, and the
/// issuer's burn from any holder.
contract MockStockToken is ERC20 {
    bool public paused;
    bool public oraclePaused;

    constructor(string memory symbol_) ERC20(symbol_, symbol_) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setPaused(bool value) external {
        paused = value;
    }

    function setOraclePaused(bool value) external {
        oraclePaused = value;
    }

    /// The issuer's adminBurn on any holder, the Reserve included (SPEC 3.2a). It also burns
    /// while the token is paused: the harder case for the Reserve.
    function adminBurn(address from, uint256 amount) external {
        super._update(from, address(0), amount);
    }

    function _update(address from, address to, uint256 value) internal override {
        require(!paused, "MockStockToken: paused");
        super._update(from, to, value);
    }
}
