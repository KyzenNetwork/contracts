// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// Answers the getters `KyznToken.setProtocolAddresses` reads (`kyzn`, `weth`, `reserve`,
/// `router`) with fixed values, so one stub can stand in for the Reserve, Staking or the Gateway
/// and each read can be made to match or miss on its own.
contract ProtocolStub {
    address public kyzn;
    address public weth;
    address public reserve;
    address public router;

    constructor(address kyzn_, address weth_, address reserve_, address router_) {
        kyzn = kyzn_;
        weth = weth_;
        reserve = reserve_;
        router = router_;
    }
}

/// A ProtocolStub that takes ETH, refuses it, or burns all the gas it is given, as set: a Reserve
/// or Staking that accepts its tax share, or one that cannot.
contract PayableProtocolStub is ProtocolStub {
    enum Mode {
        Accept,
        Refuse,
        BurnGas
    }

    Mode public mode;

    constructor(address kyzn_, address weth_, address reserve_, address router_, Mode mode_)
        ProtocolStub(kyzn_, weth_, reserve_, router_)
    {
        mode = mode_;
    }

    function setMode(Mode mode_) external {
        mode = mode_;
    }

    receive() external payable {
        if (mode == Mode.Refuse) revert("PayableProtocolStub: refuses ETH");
        if (mode == Mode.BurnGas) {
            while (true) {}
        }
    }
}
