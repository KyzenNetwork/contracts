// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {IReserveView} from "./interfaces/IReserveView.sol";
import {PriceLib} from "./lib/PriceLib.sol";

/// @title Kyzen Network Staking (SPEC 3.3)
/// @notice Unlocked staking of $KYZN for 1% of every trade. The ETH collects here; once every
/// 24 hours anyone calls notifyRewards() and that ETH streams to stakers per second over the
/// next 24 hours, pro-rata to stake (the Synthetix StakingRewards pattern, paid in ETH).
/// ETH that streams while nothing is staked rolls into the next funding. Rewards never expire.
contract Staking is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum PayoutMode {
        Eth,
        Compound,
        Equity
    }

    uint256 public constant FUNDING_INTERVAL = 24 hours;
    uint256 public constant STREAM_DURATION = 24 hours;
    uint256 public constant MAX_FEED_AGE = 24 hours;
    uint256 public constant PRICE_BOUND_BPS = 9_850;
    uint256 public constant BPS = 10_000;
    uint256 private constant PRECISION = 1e36;

    IERC20 public immutable kyzn;
    IUniswapV2Router02 public immutable router;
    IWETH public immutable weth;
    IReserveView public immutable reserve;
    /// The chip-equity payout buys one of these two (NVDA and AMD).
    address public immutable equityAssetA;
    address public immutable equityAssetB;

    uint256 public totalStaked;
    mapping(address => uint256) public stakedOf;
    mapping(address => PayoutMode) public payoutMode;
    bool public equityEnabled;
    /// The one address beside the token that may send staking ETH: later protocol revenue, such as
    /// the stakers' share of Silicon synthetics fees (SPEC 3.5). None until the owner sets it.
    address public feeSource;

    uint256 public rewardRate; // wei per second
    uint256 public periodFinish;
    uint256 public lastUpdateTime;
    uint256 public rewardPerTokenStored;
    uint256 public lastFundedAt;
    /// What the last funding streams, ETH rolled over from earlier fundings included.
    uint256 public lastFundingAmount;
    /// ETH put into reward streams so far, each wei counted once: ETH that streams while nothing
    /// is staked rolls into the next funding and streams again, but is not counted again. Each
    /// funding raises it to what stakers were credited plus what now streams (it never
    /// decreases), so it never exceeds the ETH received and trails it only by what arrived since
    /// the last funding and the under-86,400-wei rounding that funding leaves for the next.
    uint256 public totalFunded;
    /// ETH credited to stakers so far; never less than what they have earned.
    uint256 public totalAllocated;
    /// ETH paid out so far, in any mode.
    uint256 public totalPaid;
    mapping(address => uint256) public userRewardPerTokenPaid;
    mapping(address => uint256) public rewards;

    event Staked(address indexed account, uint256 amount);
    event Withdrawn(address indexed account, uint256 amount);
    event RewardsNotified(uint256 amount, uint256 periodFinish);
    event RewardPaid(address indexed account, PayoutMode mode, uint256 ethAmount, address asset, uint256 assetAmount);
    event PayoutModeSet(address indexed account, PayoutMode mode);
    event EquityEnabledSet(bool enabled);
    event FeeSourceSet(address indexed source);

    error ZeroAddress();
    error ZeroAmount();
    error TooSoon();
    error NothingToClaim();
    error EthSendFailed();
    error EquityDisabled();
    error BadAsset();
    error BadTarget();
    error OutsideWindow();
    error FeedPaused(address asset);
    error PartialFill();
    error PriceBound(uint256 received, uint256 required);
    error AmountAboveEarned();
    error NotTokenOrFeeSource();

    constructor(
        IERC20 kyzn_,
        IUniswapV2Router02 router_,
        IReserveView reserve_,
        address equityAssetA_,
        address equityAssetB_
    ) Ownable(msg.sender) {
        if (
            address(kyzn_) == address(0) || address(router_) == address(0) || address(reserve_) == address(0)
                || equityAssetA_ == address(0) || equityAssetB_ == address(0)
        ) revert ZeroAddress();
        kyzn = kyzn_;
        router = router_;
        weth = IWETH(router_.WETH());
        reserve = reserve_;
        equityAssetA = equityAssetA_;
        equityAssetB = equityAssetB_;
    }

    /// The 1% tax share arrives here as ETH from the token, and later protocol revenue from the fee
    /// source; from no one else: ETH from anyone would stream to stakers and, through Compound, buy
    /// $KYZN untaxed for a staker who holds nearly all of the stake.
    receive() external payable {
        // msg.sender is never zero, so while no fee source is set only the token matches.
        if (msg.sender != address(kyzn) && msg.sender != feeSource) revert NotTokenOrFeeSource();
    }

    // ---------------------------------------------------------------- staking

    function stake(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _checkpoint(msg.sender);
        uint256 before = kyzn.balanceOf(address(this));
        kyzn.safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = kyzn.balanceOf(address(this)) - before;
        stakedOf[msg.sender] += received;
        totalStaked += received;
        emit Staked(msg.sender, received);
    }

    /// No lock, no fee: unstake any amount at any time. Earned rewards stay claimable.
    function withdraw(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _checkpoint(msg.sender);
        stakedOf[msg.sender] -= amount;
        totalStaked -= amount;
        kyzn.safeTransfer(msg.sender, amount);
        emit Withdrawn(msg.sender, amount);
    }

    // ---------------------------------------------------------------- funding

    /// Anyone, once every 24 hours: everything not owed to stakers streams over the next 24 hours.
    function notifyRewards() external nonReentrant {
        if (lastFundedAt != 0 && block.timestamp < lastFundedAt + FUNDING_INTERVAL) revert TooSoon();
        _checkpoint(address(0));
        uint256 pool = address(this).balance - (totalAllocated - totalPaid);
        rewardRate = pool / STREAM_DURATION;
        uint256 amount = rewardRate * STREAM_DURATION;
        lastUpdateTime = block.timestamp;
        periodFinish = block.timestamp + STREAM_DURATION;
        lastFundedAt = block.timestamp;
        lastFundingAmount = amount;
        // Credited so far plus streaming now. ETH that rolled over was never credited, so it is
        // in `amount` again but not in totalAllocated: counted once.
        uint256 funded = totalAllocated + amount;
        if (funded > totalFunded) totalFunded = funded;
        emit RewardsNotified(amount, periodFinish);
    }

    // ---------------------------------------------------------------- payouts

    /// The staker's chosen payout mode. Chip equity needs the owner switch (after counsel review).
    function setPayoutMode(PayoutMode mode) external {
        if (mode == PayoutMode.Equity && !equityEnabled) revert EquityDisabled();
        payoutMode[msg.sender] = mode;
        emit PayoutModeSet(msg.sender, mode);
    }

    /// Pays all earned rewards in ETH.
    function claim() external nonReentrant returns (uint256 amount) {
        amount = _takeAll(msg.sender);
        (bool ok,) = msg.sender.call{value: amount}("");
        if (!ok) revert EthSendFailed();
        emit RewardPaid(msg.sender, PayoutMode.Eth, amount, address(0), 0);
    }

    /// Buys $KYZN with all earned rewards, tax-free (Staking is exempt), and adds it to the stake.
    function claimCompound(uint256 minKyznOut) external nonReentrant returns (uint256 added) {
        uint256 amount = _takeAll(msg.sender);
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(kyzn);
        uint256 before = kyzn.balanceOf(address(this));
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: amount}(
            minKyznOut, path, address(this), block.timestamp
        );
        added = kyzn.balanceOf(address(this)) - before;
        stakedOf[msg.sender] += added;
        totalStaked += added;
        emit RewardPaid(msg.sender, PayoutMode.Compound, amount, address(kyzn), added);
        emit Staked(msg.sender, added);
    }

    /// Buys NVDA or AMD with `ethAmount` of the caller's earned ETH, through a swap target the
    /// Reserve allows, under the Reserve's purchase window, feed freshness and 98.5% price bound,
    /// and sends it to the staker. The caller names the amount, so a quote stays valid while
    /// rewards keep streaming; the rest stays claimable. The Reserve's isTargetAllowed applies
    /// the one swap-target rule for both contracts (never $KYZN, WETH, the pair, the Reserve,
    /// Staking, or a listed or pending asset), so Staking keeps no copy of it.
    function claimEquity(address asset, uint256 ethAmount, address target, bytes calldata data, uint256 minOut)
        external
        nonReentrant
        returns (uint256 received)
    {
        if (!equityEnabled) revert EquityDisabled();
        if (asset != equityAssetA && asset != equityAssetB) revert BadAsset();
        if (!reserve.isTargetAllowed(target)) revert BadTarget();
        if (!PriceLib.inPurchaseWindow(block.timestamp)) revert OutsideWindow();
        _checkpoint(msg.sender);
        _debit(msg.sender, ethAmount);
        uint256 bound = Math.mulDiv(ethAmount, _ethPrice(), _assetPrice(asset)) * PRICE_BOUND_BPS / BPS;
        received = _buyAsset(asset, target, data, ethAmount);
        uint256 required = bound > minOut ? bound : minOut;
        if (received < required) revert PriceBound(received, required);
        IERC20(asset).safeTransfer(msg.sender, received);
        emit RewardPaid(msg.sender, PayoutMode.Equity, ethAmount, asset, received);
    }

    /// The fee source: a protocol contract that forwards revenue to stakers (zero for none).
    function setFeeSource(address source) external onlyOwner {
        feeSource = source;
        emit FeeSourceSet(source);
    }

    /// The chip-equity switch, off until counsel review (SPEC 3.3).
    function setEquityEnabled(bool enabled) external onlyOwner {
        equityEnabled = enabled;
        emit EquityEnabledSet(enabled);
    }

    // ---------------------------------------------------------------- views

    function rewardPerToken() external view returns (uint256 rpt) {
        (rpt,) = _accrued();
    }

    /// ETH this account can claim now.
    function earned(address account) external view returns (uint256) {
        (uint256 rpt,) = _accrued();
        return _earned(account, rpt);
    }

    /// When notifyRewards() next becomes callable (a past time means now).
    function nextFundingAt() external view returns (uint256) {
        return lastFundedAt + FUNDING_INTERVAL;
    }

    // ---------------------------------------------------------------- internals

    /// Reward per token now, and the ETH that accrual allocates, rounded up so allocations
    /// always cover what stakers can claim.
    function _accrued() private view returns (uint256 rpt, uint256 allocated) {
        rpt = rewardPerTokenStored;
        uint256 end = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (totalStaked == 0 || end <= lastUpdateTime) return (rpt, 0);
        uint256 increment = Math.mulDiv((end - lastUpdateTime) * rewardRate, PRECISION, totalStaked);
        rpt += increment;
        allocated = Math.mulDiv(increment, totalStaked, PRECISION, Math.Rounding.Ceil);
    }

    function _earned(address account, uint256 rpt) private view returns (uint256) {
        return rewards[account] + Math.mulDiv(stakedOf[account], rpt - userRewardPerTokenPaid[account], PRECISION);
    }

    function _checkpoint(address account) private {
        (uint256 rpt, uint256 allocated) = _accrued();
        rewardPerTokenStored = rpt;
        totalAllocated += allocated;
        uint256 end = block.timestamp < periodFinish ? block.timestamp : periodFinish;
        if (end > lastUpdateTime) lastUpdateTime = end;
        if (account != address(0)) {
            rewards[account] = _earned(account, rpt);
            userRewardPerTokenPaid[account] = rpt;
        }
    }

    function _takeAll(address account) private returns (uint256 amount) {
        _checkpoint(account);
        amount = rewards[account];
        _debit(account, amount);
    }

    function _debit(address account, uint256 amount) private {
        if (amount == 0) revert NothingToClaim();
        if (amount > rewards[account]) revert AmountAboveEarned();
        rewards[account] -= amount;
        totalPaid += amount;
    }

    function _ethPrice() private view returns (uint256) {
        return PriceLib.fresh(reserve.ethUsdFeed(), reserve.ethUsdDecimals(), MAX_FEED_AGE);
    }

    function _assetPrice(address asset) private view returns (uint256) {
        (address feed, uint8 feedDecimals,,, bool listed) = reserve.assetInfo(asset);
        if (!listed) revert BadAsset();
        if (IStockToken(asset).oraclePaused()) revert FeedPaused(asset);
        return PriceLib.fresh(feed, feedDecimals, MAX_FEED_AGE);
    }

    /// Wraps `amount` ETH, lets the target pull exactly that WETH, and returns the asset received.
    function _buyAsset(address asset, address target, bytes calldata data, uint256 amount)
        private
        returns (uint256 received)
    {
        IERC20 w = IERC20(address(weth));
        uint256 wethBefore = w.balanceOf(address(this));
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        weth.deposit{value: amount}();
        w.forceApprove(target, amount);
        Address.functionCall(target, data);
        w.forceApprove(target, 0);
        if (w.balanceOf(address(this)) != wethBefore) revert PartialFill();
        received = IERC20(asset).balanceOf(address(this)) - assetBefore;
    }
}
