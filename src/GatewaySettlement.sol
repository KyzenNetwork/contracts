// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IKyzn} from "./interfaces/IKyzn.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2.sol";

/// @title Kyzen Network Gateway settlement (SPEC 3.6)
/// @notice Holds the $KYZN paid for inference. Per settlement window the operator sells what
/// the host bill needs, for ETH sent to the host-payout address (the wallet that pays the
/// inference host; the owner sets it), and burns the rest.
/// The price is the host rate x 1.10, so 1/11 of every payment is margin: each settlement
/// burns at least 1/11 of what it settles. Sales are tax-exempt, so the full margin burns.
contract GatewaySettlement is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IKyzn public immutable kyzn;
    IUniswapV2Router02 public immutable router;
    address public hostPayout;
    address public operator;

    /// Lifetime sums across every settlement window (SPEC 3.6).
    uint256 public totalSold;
    uint256 public totalBurned;
    uint256 public totalToHost;

    event OperatorSet(address indexed operator);
    event HostPayoutSet(address indexed hostPayout);
    event Settled(uint256 sold, uint256 burned, uint256 ethToHost);

    error ZeroAddress();
    error NotOperator();
    error NothingToSettle();
    error BurnBelowMargin();

    constructor(IKyzn kyzn_, IUniswapV2Router02 router_, address hostPayout_) Ownable(msg.sender) {
        if (address(kyzn_) == address(0) || address(router_) == address(0) || hostPayout_ == address(0)) {
            revert ZeroAddress();
        }
        kyzn = kyzn_;
        router = router_;
        hostPayout = hostPayout_;
        emit HostPayoutSet(hostPayout_);
    }

    /// The wallet the host bill's ETH goes to. It does not touch the burn: every settlement still
    /// burns at least 1/11.
    function setHostPayout(address hostPayout_) external onlyOwner {
        if (hostPayout_ == address(0)) revert ZeroAddress();
        hostPayout = hostPayout_;
        emit HostPayoutSet(hostPayout_);
    }

    function setOperator(address operator_) external onlyOwner {
        operator = operator_;
        emit OperatorSet(operator_);
    }

    /// Burns `burnAmount` and sells `sellAmount` for ETH to the host payout address.
    /// burned >= (sold + burned) / 11, that is 10 x burned >= sold.
    function settle(uint256 sellAmount, uint256 burnAmount, uint256 minEthOut)
        external
        nonReentrant
        returns (uint256 ethToHost)
    {
        if (msg.sender != operator) revert NotOperator();
        if (sellAmount == 0 && burnAmount == 0) revert NothingToSettle();
        if (burnAmount * 10 < sellAmount) revert BurnBelowMargin();
        if (burnAmount != 0) kyzn.burn(burnAmount);
        if (sellAmount != 0) {
            IERC20(address(kyzn)).forceApprove(address(router), sellAmount);
            address[] memory path = new address[](2);
            path[0] = address(kyzn);
            path[1] = router.WETH();
            uint256 before = hostPayout.balance;
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                sellAmount, minEthOut, path, hostPayout, block.timestamp
            );
            uint256 afterSale = hostPayout.balance;
            ethToHost = afterSale > before ? afterSale - before : 0;
        }
        totalSold += sellAmount;
        totalBurned += burnAmount;
        totalToHost += ethToHost;
        emit Settled(sellAmount, burnAmount, ethToHost);
    }
}
