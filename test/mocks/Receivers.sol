// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// Rejects every ETH transfer.
contract RejectingReceiver {
    receive() external payable {
        revert("RejectingReceiver");
    }
}

/// Burns all gas it is given on receiving ETH.
contract GasBurner {
    receive() external payable {
        while (true) {}
    }
}
