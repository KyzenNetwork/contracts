// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {IWETH} from "../interfaces/IWETH.sol";

/// @title Kyzen Network Silicon fee router (SPEC 3.5)
/// @notice Collects Silicon revenue (fee synth, USDG, collateral from auctions, ETH) and pays it
/// out as ETH: the Reserve's share to the Reserve, the stakers' share to Staking, which must name
/// this router as its fee source.
///
/// The keeper converts what arrives into WETH or ETH through a swap target the owner has
/// allowlisted, with the same 24-hour public delay as the Reserve's targets, and names the least
/// it accepts. Anyone may then call distribute(). The split has no default: distribute() reverts
/// until the owner sets it.
contract SiliconFeeRouter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    /// 100%, in basis points.
    uint256 public constant BPS = 10_000;
    /// Delay before a swap-target change takes effect.
    uint256 public constant TARGET_DELAY = 24 hours;

    /// A swap target's state: live now, and any change waiting for its 24 hours.
    struct TargetState {
        bool allowed;
        bool pendingAllowed;
        uint64 effectiveAt; // 0 when no change is pending
    }

    /// WETH, unwrapped before each distribution.
    IWETH public immutable weth;
    /// The address that runs conversions (none until the owner sets it).
    address public keeper;
    /// The Reserve, paid its share in ETH.
    address public reserve;
    /// Staking, paid the stakers' share in ETH; it must name this router as its fee source.
    address public staking;
    /// The Reserve's share of each distribution; the stakers receive the rest.
    uint256 public reserveShareBps;
    /// Whether the owner has set the split.
    bool public splitSet;
    /// ETH sent to the Reserve so far.
    uint256 public totalToReserve;
    /// ETH sent to Staking so far.
    uint256 public totalToStakers;
    mapping(address => TargetState) private _targets;

    /// The owner named the keeper.
    event KeeperSet(address indexed keeper);
    /// The owner named the Reserve.
    event ReserveSet(address indexed reserve);
    /// The owner named Staking.
    event StakingSet(address indexed staking);
    /// The owner set the Reserve's share; the stakers receive the rest.
    event SplitSet(uint256 reserveShareBps);
    /// A swap-target change, effective at `effectiveAt`.
    event TargetQueued(address indexed target, bool allowed, uint256 effectiveAt);
    /// The keeper converted `spent` of `tokenIn` into `received` wei of WETH or ETH.
    event Converted(address indexed tokenIn, address indexed target, uint256 spent, uint256 received);
    /// ETH paid out to the Reserve and to Staking.
    event Distributed(uint256 toReserve, uint256 toStakers);

    /// An address is zero.
    error ZeroAddress();
    /// An amount is zero.
    error ZeroAmount();
    /// The caller is not the keeper.
    error NotKeeper();
    /// The target is not allowlisted, or never may be.
    error BadTarget();
    /// WETH is already what the router pays out; nothing to convert.
    error BadToken();
    /// A share above 100%.
    error BpsAboveMaximum(uint256 bps, uint256 maximum);
    /// The conversion returned less than the keeper's minimum.
    error InsufficientOutput(uint256 received, uint256 minimum);
    /// The owner has not set the split yet.
    error SplitUnset();
    /// The owner has not named the Reserve and Staking yet.
    error RecipientsUnset();
    /// No ETH or WETH to distribute.
    error NothingToDistribute();
    /// A recipient refused the ETH (Staking takes ETH only from its fee source).
    error EthSendFailed();

    modifier onlyKeeper() {
        _checkKeeper();
        _;
    }

    /// `weth_` is the WETH that swap targets pay and distribute() unwraps.
    constructor(IWETH weth_) Ownable(msg.sender) {
        if (address(weth_) == address(0)) revert ZeroAddress();
        weth = weth_;
    }

    /// ETH from swap targets, unwrapped WETH, and anyone who sends it.
    receive() external payable {}

    // ---------------------------------------------------------------- owner

    /// Names the keeper; zero stops conversions.
    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// Names the Reserve.
    function setReserve(address reserve_) external onlyOwner {
        if (reserve_ == address(0)) revert ZeroAddress();
        reserve = reserve_;
        emit ReserveSet(reserve_);
    }

    /// Staking must name this router as its fee source, or distribute() reverts.
    function setStaking(address staking_) external onlyOwner {
        if (staking_ == address(0)) revert ZeroAddress();
        staking = staking_;
        emit StakingSet(staking_);
    }

    /// The Reserve's share of each distribution, in basis points; the stakers receive the rest.
    function setSplit(uint256 reserveShareBps_) external onlyOwner {
        if (reserveShareBps_ > BPS) revert BpsAboveMaximum(reserveShareBps_, BPS);
        reserveShareBps = reserveShareBps_;
        splitSet = true;
        emit SplitSet(reserveShareBps_);
    }

    /// Allow or disallow a swap target. The change takes effect 24 hours after this call.
    function queueTarget(address target, bool allowed) external onlyOwner {
        if (_isForbiddenTarget(target)) revert BadTarget();
        TargetState storage t = _targets[target];
        if (t.effectiveAt != 0 && block.timestamp >= t.effectiveAt) t.allowed = t.pendingAllowed;
        t.pendingAllowed = allowed;
        // A uint64 timestamp lasts hundreds of billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        t.effectiveAt = uint64(block.timestamp + TARGET_DELAY);
        emit TargetQueued(target, allowed, t.effectiveAt);
    }

    // ---------------------------------------------------------------- keeper

    /// Keeper only: lets `target` pull up to `amountIn` of `tokenIn`, calls it with `data`, and
    /// requires at least `minOut` wei of WETH and ETH together to arrive during the call.
    function convert(address tokenIn, address target, bytes calldata data, uint256 amountIn, uint256 minOut)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 received)
    {
        if (amountIn == 0) revert ZeroAmount();
        if (tokenIn == address(weth) || tokenIn == address(0)) revert BadToken();
        if (target == tokenIn || !isTargetAllowed(target)) revert BadTarget();
        IERC20 token = IERC20(tokenIn);
        uint256 ethBefore = _ethHeld();
        uint256 tokenBefore = token.balanceOf(address(this));
        token.forceApprove(target, amountIn);
        Address.functionCall(target, data);
        token.forceApprove(target, 0);
        uint256 tokenAfter = token.balanceOf(address(this));
        // Nothing here lets a target take WETH or ETH, so the balance can only grow.
        received = _ethHeld() - ethBefore;
        if (received < minOut) revert InsufficientOutput(received, minOut);
        emit Converted(tokenIn, target, tokenBefore > tokenAfter ? tokenBefore - tokenAfter : 0, received);
    }

    // ---------------------------------------------------------------- distribution

    /// Anyone: unwraps the WETH held and sends all ETH held, the Reserve's share to the Reserve
    /// and the rest to Staking.
    function distribute() external nonReentrant returns (uint256 toReserve, uint256 toStakers) {
        if (!splitSet) revert SplitUnset();
        if (reserve == address(0) || staking == address(0)) revert RecipientsUnset();
        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance != 0) weth.withdraw(wethBalance);
        uint256 amount = address(this).balance;
        if (amount == 0) revert NothingToDistribute();
        toReserve = amount * reserveShareBps / BPS;
        toStakers = amount - toReserve;
        totalToReserve += toReserve;
        totalToStakers += toStakers;
        _sendEth(reserve, toReserve);
        _sendEth(staking, toStakers);
        emit Distributed(toReserve, toStakers);
    }

    // ---------------------------------------------------------------- views

    /// Whether a swap target is live now. Always false for a target the rule forbids: the zero
    /// address, this router, WETH, the Reserve or Staking.
    function isTargetAllowed(address target) public view returns (bool) {
        if (_isForbiddenTarget(target)) return false;
        TargetState memory t = _targets[target];
        if (t.effectiveAt != 0 && block.timestamp >= t.effectiveAt) return t.pendingAllowed;
        return t.allowed;
    }

    /// A queued change: whether it allows the target, and when it takes effect (0 for none pending).
    function pendingTarget(address target) external view returns (bool allowed, uint256 effectiveAt) {
        TargetState memory t = _targets[target];
        if (t.effectiveAt == 0 || block.timestamp >= t.effectiveAt) return (false, 0);
        return (t.pendingAllowed, t.effectiveAt);
    }

    // ---------------------------------------------------------------- internals

    function _checkKeeper() private view {
        if (msg.sender != keeper) revert NotKeeper();
    }

    function _isForbiddenTarget(address target) private view returns (bool) {
        return target == address(0) || target == address(this) || target == address(weth) || target == reserve
            || target == staking;
    }

    function _ethHeld() private view returns (uint256) {
        return address(this).balance + weth.balanceOf(address(this));
    }

    function _sendEth(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthSendFailed();
    }
}
