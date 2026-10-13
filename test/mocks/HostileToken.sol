// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// An 18-decimal token that turns on its holders, the way a broken or upgraded listing could
/// (the Reserve never delists): balanceOf and transfer can revert, burn every unit of gas
/// they are given, or answer with malformed data. balanceOf can also answer the largest
/// uint256. A transfer that does not answer true or nothing moves no tokens. paused and
/// oraclePaused are always false, so this also stands in for a Robinhood Stock Token when a
/// test needs to buy or sell it, not just hold it.
contract HostileToken is ERC20 {
    enum Mode {
        Normal,
        Revert,
        BurnGas,
        ShortAnswer,
        AnswerFalse,
        AnswerNothing,
        AnswerHuge
    }

    Mode public balanceMode;
    Mode public transferMode;

    constructor() ERC20("Hostile", "HOSTILE") {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function paused() external pure returns (bool) {
        return false;
    }

    function oraclePaused() external pure returns (bool) {
        return false;
    }

    function setBalanceMode(Mode mode) external {
        balanceMode = mode;
    }

    function setTransferMode(Mode mode) external {
        transferMode = mode;
    }

    function balanceOf(address account) public view override returns (uint256) {
        Mode mode = balanceMode;
        if (mode == Mode.Revert) revert("HostileToken: balanceOf");
        if (mode == Mode.BurnGas) _burnGas();
        if (mode == Mode.ShortAnswer) _answerShort();
        if (mode == Mode.AnswerHuge) return type(uint256).max;
        return super.balanceOf(account);
    }

    function transfer(address to, uint256 amount) public override returns (bool) {
        Mode mode = transferMode;
        if (mode == Mode.Revert) revert("HostileToken: transfer");
        if (mode == Mode.BurnGas) _burnGas();
        if (mode == Mode.ShortAnswer) _answerShort();
        if (mode == Mode.AnswerFalse) return false;
        _transfer(msg.sender, to, amount);
        if (mode == Mode.AnswerNothing) {
            assembly ("memory-safe") {
                return(0, 0)
            }
        }
        return true;
    }

    function _burnGas() private pure {
        while (true) {}
    }

    /// Ends the call with 16 bytes of return data, half an ABI word.
    function _answerShort() private pure {
        assembly ("memory-safe") {
            mstore(0, 1)
            return(0, 16)
        }
    }
}
