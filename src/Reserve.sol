// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IKyzn} from "./interfaces/IKyzn.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {IStockToken} from "./interfaces/IStockToken.sol";
import {IRotationState} from "./interfaces/IRotationState.sol";
import {IReserveView} from "./interfaces/IReserveView.sol";
import {PriceLib} from "./lib/PriceLib.sol";

/// @title Kyzen Network Reserve (SPEC 3.2)
/// @notice Holds the ETH from 2% of every trade and the chip stock tokens a keeper buys with
/// it under the buy discipline. Anyone can burn $KYZN here for a pro-rata share of every
/// asset at backing minus 2%, computed against total supply. Redemption pays in kind and
/// reads no prices.
contract Reserve is Ownable2Step, ReentrancyGuard, IReserveView {
    using SafeERC20 for IERC20;

    uint256 public constant BPS = 10_000;
    /// Redemption pays backing minus 2%; the 2% stays in the Reserve.
    uint256 public constant REDEMPTION_BPS = 9_800;
    uint256 public constant MAX_SLICE = 1 ether;
    uint256 public constant MIN_SPACING = 15 minutes;
    uint256 public constant MAX_FEED_AGE = 24 hours;
    /// A trade must receive at least 98.5% of what the Chainlink prices imply.
    uint256 public constant PRICE_BOUND_BPS = 9_850;
    uint256 public constant STAGE_CAP_BPS = 5_000;
    /// Delay before a swap-target change, or a listing queued by addAsset, takes effect.
    uint256 public constant TARGET_DELAY = 24 hours;
    uint256 public constant MAX_ASSETS = 16;
    /// Design, memory, fab, equipment, power.
    uint8 public constant STAGES = 5;
    /// Gas for reading one asset balance. An asset whose balanceOf needs more, reverts or
    /// answers short is unreadable: redemption skips it and the views leave it out.
    uint256 public constant BALANCE_GAS = 100_000;
    /// Gas for one asset transfer in a redemption. A transfer that needs more, reverts or
    /// answers anything but true or nothing is recorded as a claim.
    uint256 public constant TRANSFER_GAS = 200_000;

    /// An asset to list: an 18-decimal stock token, its Chainlink feed and its stage (0 to 4).
    struct AssetConfig {
        address token;
        address feed;
        uint8 stage;
    }

    struct Asset {
        address feed;
        uint8 feedDecimals;
        uint8 stage;
        uint64 lastTradeAt;
        bool listed;
    }

    struct TargetState {
        bool allowed;
        bool pendingAllowed;
        uint64 effectiveAt; // 0 when no change is pending
    }

    /// A listing queued by addAsset, waiting for listAsset.
    struct PendingAsset {
        address feed;
        uint8 feedDecimals;
        uint8 stage;
        uint64 effectiveAt; // 0 when nothing is pending
    }

    IKyzn public immutable kyzn;
    IWETH public immutable weth;
    address public immutable ethUsdFeed;
    uint8 public immutable ethUsdDecimals;
    IRotationState public immutable registry;
    /// The $KYZN/WETH pair, fixed in the token when it was deployed.
    address private immutable _pair;

    address public keeper;
    address[] public assets;
    mapping(address => Asset) public assetInfo;
    mapping(address => TargetState) private _targets;
    mapping(address => PendingAsset) private _pendingAssets;
    /// Stock tokens owed to redeemers because any transfer to them failed at redemption. Claims
    /// come first: redemptions, sales and the views use only the balance above totalClaims. After
    /// an issuer burn below totalClaims, each claim pays its pro-rata part of the balance (claim).
    mapping(address => mapping(address => uint256)) public claims;
    mapping(address => uint256) public totalClaims;

    event KeeperSet(address indexed keeper);
    event AssetQueued(address indexed token, address feed, uint8 stage, uint256 effectiveAt);
    event AssetCancelled(address indexed token);
    event AssetAdded(address indexed token, address feed, uint8 stage);
    event TargetQueued(address indexed target, bool allowed, uint256 effectiveAt);
    event Bought(address indexed asset, address indexed target, uint256 ethSpent, uint256 received);
    event Sold(address indexed asset, address indexed target, uint256 amountSold, uint256 ethReceived);
    event Redeemed(address indexed account, uint256 kyznBurned, uint256 ethPaid);
    event AssetPaid(address indexed account, address indexed asset, uint256 amount);
    event AssetUnreadable(address indexed asset);
    event ClaimRecorded(address indexed account, address indexed asset, uint256 amount);
    /// `amount` is what was paid: the whole claim, or its pro-rata part after an issuer burn.
    event Claimed(address indexed account, address indexed asset, uint256 amount);

    error ZeroAddress();
    error NotKeeper();
    error BadAsset();
    error BadFeed();
    error BadStage();
    error AssetListed();
    error AssetPending();
    error NotPending();
    error TooManyAssets();
    error NotListed();
    error BadTarget();
    error OutsideWindow();
    error TooSoon();
    error BadAmount();
    error FeedPaused(address asset);
    error PriceBound(uint256 received, uint256 required);
    error NoRotationYet();
    error NotAboveCap();
    error NothingToClaim();
    error EthSendFailed();
    error UnreadableAsset(address asset);

    modifier onlyKeeper() {
        _checkKeeper();
        _;
    }

    /// Lists `initialAssets` at once; every asset added later waits 24 hours in public.
    constructor(
        IKyzn kyzn_,
        IWETH weth_,
        address ethUsdFeed_,
        IRotationState registry_,
        AssetConfig[] memory initialAssets
    ) Ownable(msg.sender) {
        if (
            address(kyzn_) == address(0) || address(weth_) == address(0) || ethUsdFeed_ == address(0)
                || address(registry_) == address(0)
        ) revert ZeroAddress();
        uint8 d = IAggregatorV3(ethUsdFeed_).decimals();
        if (d > 18) revert BadFeed();
        kyzn = kyzn_;
        weth = weth_;
        ethUsdFeed = ethUsdFeed_;
        ethUsdDecimals = d;
        registry = registry_;
        _pair = kyzn_.pair();
        for (uint256 i; i < initialAssets.length; ++i) {
            AssetConfig memory c = initialAssets[i];
            _list(c.token, c.feed, _checkNewAsset(c.token, c.feed, c.stage), c.stage);
        }
    }

    /// Tax ETH from the token contract, unwrapped WETH and sale proceeds.
    receive() external payable {}

    // ---------------------------------------------------------------- owner powers (SPEC 3.2)

    function setKeeper(address keeper_) external onlyOwner {
        keeper = keeper_;
        emit KeeperSet(keeper_);
    }

    /// Add only: an asset is never removed. The listing waits 24 hours in public (AssetQueued) and
    /// takes effect only when the owner calls listAsset.
    function addAsset(address token, address feed, uint8 stage) external onlyOwner {
        uint8 d = _checkNewAsset(token, feed, stage);
        // A uint64 timestamp lasts hundreds of billions of years.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 effectiveAt = uint64(block.timestamp + TARGET_DELAY);
        _pendingAssets[token] = PendingAsset({feed: feed, feedDecimals: d, stage: stage, effectiveAt: effectiveAt});
        emit AssetQueued(token, feed, stage, effectiveAt);
    }

    /// Lists a queued asset, once its 24 hours have passed.
    function listAsset(address token) external onlyOwner {
        PendingAsset memory p = _pendingAssets[token];
        if (p.effectiveAt == 0) revert NotPending();
        if (block.timestamp < p.effectiveAt) revert TooSoon();
        if (assets.length == MAX_ASSETS) revert TooManyAssets();
        delete _pendingAssets[token];
        _list(token, p.feed, p.feedDecimals, p.stage);
    }

    /// Drops a pending listing.
    function cancelAsset(address token) external onlyOwner {
        if (_pendingAssets[token].effectiveAt == 0) revert NotPending();
        delete _pendingAssets[token];
        emit AssetCancelled(token);
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

    // ---------------------------------------------------------------- keeper trades

    /// Buys `asset` with at most 1 ETH through an allowlisted target in the purchase window.
    /// The contract wraps the ETH, approves exactly that WETH, calls the target and requires
    /// the tokens received to meet the Chainlink price bound and the keeper's minimum. Reverts
    /// UnreadableAsset if the asset's balance cannot be read at BALANCE_GAS, the same cap
    /// redemption uses, so the keeper can never buy into a holding that redemption would then
    /// skip.
    function buy(address asset, address target, bytes calldata data, uint256 ethIn, uint256 minOut)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 received)
    {
        if (ethIn == 0 || ethIn > MAX_SLICE) revert BadAmount();
        Asset storage a = _checkTrade(asset, target);
        (uint256 ethPrice, uint256 assetPrice) = _tradePrices(asset, a);
        uint256 spent;
        (spent, received) = _swapEthForAsset(asset, target, data, ethIn);
        _checkOut(received, Math.mulDiv(spent, ethPrice, assetPrice) * PRICE_BOUND_BPS / BPS, minOut);
        a.lastTradeAt = uint64(block.timestamp);
        emit Bought(asset, target, spent, received);
    }

    /// Sells `asset` for WETH, only from the first rotation on and only while the asset's stage
    /// holds more than 50% of Reserve value, never selling more than the excess and never selling
    /// more than the unclaimed balance. The target must pay WETH; native ETH arriving during the
    /// call is not counted as proceeds.
    function sell(address asset, address target, bytes calldata data, uint256 amountIn, uint256 minEthOut)
        external
        onlyKeeper
        nonReentrant
        returns (uint256 ethOut)
    {
        if (!registry.hasExecuted()) revert NoRotationYet();
        Asset storage a = _checkTrade(asset, target);
        (uint256 ethPrice, uint256 assetPrice) = _tradePrices(asset, a);
        (, uint256 available) = _available(asset);
        uint256 saleValue = Math.mulDiv(amountIn, assetPrice, 1e18);
        if (amountIn == 0 || amountIn > available || Math.mulDiv(saleValue, 1e18, ethPrice) > MAX_SLICE) {
            revert BadAmount();
        }
        _checkAboveCap(a.stage, ethPrice, saleValue);
        uint256 sold;
        (sold, ethOut) = _swapAssetForEth(asset, target, data, amountIn);
        _checkOut(ethOut, Math.mulDiv(sold, assetPrice, ethPrice) * PRICE_BOUND_BPS / BPS, minEthOut);
        a.lastTradeAt = uint64(block.timestamp);
        emit Sold(asset, target, sold, ethOut);
    }

    // ---------------------------------------------------------------- redemption (SPEC 3.2)

    /// Burns `amount` $KYZN and pays the caller amount / totalSupply x 98% of the ETH and of
    /// every asset. A token that cannot be transferred, for example one the issuer has paused,
    /// is recorded as a claim instead. An asset whose balance cannot be read is skipped with
    /// AssetUnreadable, and nothing is paid or owed in it, so one broken token never blocks
    /// redemption.
    function redeem(uint256 amount) external nonReentrant {
        if (amount == 0) revert BadAmount();
        uint256 supply = kyzn.totalSupply();
        IERC20(address(kyzn)).safeTransferFrom(msg.sender, address(this), amount);
        kyzn.burn(amount);

        uint256 wethBalance = weth.balanceOf(address(this));
        if (wethBalance != 0) weth.withdraw(wethBalance);

        uint256 num = amount * REDEMPTION_BPS;
        uint256 den = supply * BPS;
        uint256 ethOut = Math.mulDiv(address(this).balance, num, den);

        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) {
            address token = assets[i];
            (bool readable, uint256 available) = _available(token);
            if (!readable) {
                emit AssetUnreadable(token);
                continue;
            }
            uint256 out = Math.mulDiv(available, num, den);
            if (out == 0) continue;
            if (_tryTransfer(token, msg.sender, out)) {
                emit AssetPaid(msg.sender, token, out);
            } else {
                claims[token][msg.sender] += out;
                totalClaims[token] += out;
                emit ClaimRecorded(msg.sender, token, out);
            }
        }

        if (ethOut != 0) {
            (bool ok,) = msg.sender.call{value: ethOut}("");
            if (!ok) revert EthSendFailed();
        }
        emit Redeemed(msg.sender, amount, ethOut);
    }

    /// Collects a claim once the token transfers again (any failed transfer at redemption
    /// records one, a paused token for example). The claim pays in full while the Reserve's
    /// balance of the asset covers totalClaims. If the issuer has burned that balance below
    /// totalClaims, a claim pays amount x balance / totalClaims at the balance of that moment,
    /// rounded down, and clears the whole record, so claims collected at the same balance bear
    /// the same haircut. Tokens that arrive later (a keeper purchase) go first to open claims. A claim that
    /// pays nothing still clears, with no transfer, so no record is ever stuck. Reverts
    /// UnreadableAsset while the balance cannot be read, and with the token's own error while
    /// it refuses the transfer (paused); the record then stays.
    function claim(address asset) external nonReentrant {
        uint256 amount = claims[asset][msg.sender];
        if (amount == 0) revert NothingToClaim();
        uint256 owed = totalClaims[asset];
        uint256 balance = _assetBalance(asset);
        uint256 paid = balance < owed ? Math.mulDiv(amount, balance, owed) : amount;
        claims[asset][msg.sender] = 0;
        totalClaims[asset] = owed - amount;
        if (paid != 0) IERC20(asset).safeTransfer(msg.sender, paid);
        emit Claimed(msg.sender, asset, paid);
    }

    // ---------------------------------------------------------------- views

    function assetCount() external view returns (uint256) {
        return assets.length;
    }

    /// A listing waiting for listAsset; effectiveAt is 0 when none is pending.
    function pendingAsset(address token) external view returns (address feed, uint8 stage, uint64 effectiveAt) {
        PendingAsset memory p = _pendingAssets[token];
        return (p.feed, p.stage, p.effectiveAt);
    }

    /// Whether a swap target is live now. Always false for a target the one target rule
    /// forbids, whatever was queued for it; Staking applies the rule through this view.
    function isTargetAllowed(address target) public view returns (bool) {
        if (_isForbiddenTarget(target)) return false;
        TargetState memory t = _targets[target];
        if (t.effectiveAt != 0 && block.timestamp >= t.effectiveAt) return t.pendingAllowed;
        return t.allowed;
    }

    /// Reserve value in USD (18 decimals) at the last published Chainlink answers, whatever
    /// their age, and the oldest answer's update time. Claims are excluded. Never reverts on a
    /// bad asset: a holding whose balance or price cannot be read is left out of the value, and
    /// oldestUpdate is then 0, as it is when the ETH/USD answer cannot be read. A 0 therefore
    /// means the value is incomplete.
    function reserveValue() public view returns (uint256 valueUsd, uint256 oldestUpdate) {
        bool complete;
        (complete, valueUsd, oldestUpdate) = _tryValue(_ethHoldings(), ethUsdFeed, ethUsdDecimals);
        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) {
            address token = assets[i];
            (bool ok, uint256 balance) = _available(token);
            if (ok && balance == 0) continue;
            uint256 value;
            uint256 updated;
            if (ok) {
                Asset storage a = assetInfo[token];
                (ok, value, updated) = _tryValue(balance, a.feed, a.feedDecimals);
            }
            if (!ok) {
                complete = false;
                continue;
            }
            valueUsd += value;
            if (updated < oldestUpdate) oldestUpdate = updated;
        }
        if (!complete) oldestUpdate = 0;
    }

    /// Backing per $KYZN in USD (18 decimals): Reserve value divided by total supply, with the
    /// same oldestUpdate as reserveValue (0 when a holding was left out). Never reverts on a bad asset.
    function backingPerToken() external view returns (uint256 usdPerToken, uint256 oldestUpdate) {
        uint256 valueUsd;
        (valueUsd, oldestUpdate) = reserveValue();
        uint256 supply = kyzn.totalSupply();
        if (supply != 0) usdPerToken = Math.mulDiv(valueUsd, 1e18, supply);
    }

    /// Mirrors redeem(amount) exactly, asset by asset, including skipped assets: an asset whose
    /// balance cannot be read shows 0, as redeem skips it. An amount whose transfer then fails
    /// is recorded as a claim instead of paid.
    function previewRedeem(uint256 amount)
        external
        view
        returns (uint256 ethOut, address[] memory tokens, uint256[] memory amounts)
    {
        uint256 supply = kyzn.totalSupply();
        if (amount == 0 || amount > supply) revert BadAmount();
        uint256 num = amount * REDEMPTION_BPS;
        uint256 den = supply * BPS;
        ethOut = Math.mulDiv(_ethHoldings(), num, den);
        uint256 n = assets.length;
        tokens = new address[](n);
        amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            address token = assets[i];
            tokens[i] = token;
            (, uint256 available) = _available(token); // 0 when unreadable
            amounts[i] = Math.mulDiv(available, num, den);
        }
    }

    // ---------------------------------------------------------------- internals

    function _checkKeeper() private view {
        if (msg.sender != keeper) revert NotKeeper();
    }

    /// The one swap-target rule (SPEC 3.2), used by queueTarget, isTargetAllowed and every trade,
    /// and by Staking through isTargetAllowed: a target is never the zero address, $KYZN, WETH,
    /// the $KYZN/WETH pair, the Reserve, the Staking contract, or an asset listed or pending here.
    function _isForbiddenTarget(address target) private view returns (bool) {
        return target == address(0) || target == address(kyzn) || target == address(weth) || target == _pair
            || target == address(this) || assetInfo[target].listed || _pendingAssets[target].effectiveAt != 0
            || target == kyzn.staking();
    }

    /// An 18-decimal token, not $KYZN or WETH, neither listed nor pending, a feed of at most 18
    /// decimals, a valid stage and room in the list; returns the feed's decimals.
    function _checkNewAsset(address token, address feed, uint8 stage) private view returns (uint8 feedDecimals) {
        if (token == address(0) || feed == address(0)) revert ZeroAddress();
        if (token == address(kyzn) || token == address(weth)) revert BadAsset();
        if (assetInfo[token].listed) revert AssetListed();
        if (_pendingAssets[token].effectiveAt != 0) revert AssetPending();
        if (stage >= STAGES) revert BadStage();
        if (assets.length == MAX_ASSETS) revert TooManyAssets();
        if (IERC20Metadata(token).decimals() != 18) revert BadAsset();
        feedDecimals = IAggregatorV3(feed).decimals();
        if (feedDecimals > 18) revert BadFeed();
    }

    function _list(address token, address feed, uint8 feedDecimals, uint8 stage) private {
        assetInfo[token] = Asset({feed: feed, feedDecimals: feedDecimals, stage: stage, lastTradeAt: 0, listed: true});
        assets.push(token);
        emit AssetAdded(token, feed, stage);
    }

    function _checkTrade(address asset, address target) private view returns (Asset storage a) {
        a = assetInfo[asset];
        if (!a.listed) revert NotListed();
        if (!isTargetAllowed(target)) revert BadTarget();
        if (!PriceLib.inPurchaseWindow(block.timestamp)) revert OutsideWindow();
        if (block.timestamp < uint256(a.lastTradeAt) + MIN_SPACING) revert TooSoon();
    }

    function _tradePrices(address asset, Asset storage a) private view returns (uint256 ethPrice, uint256 assetPrice) {
        if (IStockToken(asset).oraclePaused()) revert FeedPaused(asset);
        ethPrice = PriceLib.fresh(ethUsdFeed, ethUsdDecimals, MAX_FEED_AGE);
        assetPrice = PriceLib.fresh(a.feed, a.feedDecimals, MAX_FEED_AGE);
    }

    function _swapEthForAsset(address asset, address target, bytes calldata data, uint256 ethIn)
        private
        returns (uint256 spent, uint256 received)
    {
        IERC20 w = IERC20(address(weth));
        uint256 wethBefore = w.balanceOf(address(this));
        uint256 assetBefore = _assetBalance(asset);
        weth.deposit{value: ethIn}();
        w.forceApprove(target, ethIn);
        Address.functionCall(target, data);
        w.forceApprove(target, 0);
        uint256 wethAfter = w.balanceOf(address(this));
        spent = wethBefore + ethIn - wethAfter;
        if (wethAfter != 0) weth.withdraw(wethAfter);
        received = _assetBalance(asset) - assetBefore;
        if (spent == 0) revert BadAmount();
    }

    /// Swaps asset for WETH through target. Only WETH received from the target counts as proceeds;
    /// native ETH that arrives during the call is not counted.
    function _swapAssetForEth(address asset, address target, bytes calldata data, uint256 amountIn)
        private
        returns (uint256 sold, uint256 ethOut)
    {
        uint256 wethBefore = weth.balanceOf(address(this));
        uint256 assetBefore = IERC20(asset).balanceOf(address(this));
        IERC20(asset).forceApprove(target, amountIn);
        Address.functionCall(target, data);
        IERC20(asset).forceApprove(target, 0);
        sold = assetBefore - IERC20(asset).balanceOf(address(this));
        uint256 wethAfter = weth.balanceOf(address(this));
        ethOut = wethAfter - wethBefore;
        if (wethAfter != 0) weth.withdraw(wethAfter);
        if (sold == 0) revert BadAmount();
    }

    /// Reverts unless the stage holds more than 50% of Reserve value and the sale is at most the
    /// excess. ETH is valued at the trade's fresh ETH/USD price and each held asset at its last
    /// published price, whatever its age (the traded asset's was just checked fresh in
    /// _tradePrices). A holding whose balance or price cannot be read is left out.
    function _checkAboveCap(uint8 stage, uint256 ethPrice, uint256 saleValue) private view {
        uint256 total = Math.mulDiv(_ethHoldings(), ethPrice, 1e18);
        uint256 stageValue;
        uint256 n = assets.length;
        for (uint256 i; i < n; ++i) {
            address token = assets[i];
            (bool ok, uint256 balance) = _available(token);
            if (!ok || balance == 0) continue;
            Asset storage a = assetInfo[token];
            uint256 value;
            (ok, value,) = _tryValue(balance, a.feed, a.feedDecimals);
            if (!ok) continue;
            total += value;
            if (a.stage == stage) stageValue += value;
        }
        uint256 cap = total * STAGE_CAP_BPS / BPS;
        if (stageValue <= cap || saleValue > stageValue - cap) revert NotAboveCap();
    }

    function _checkOut(uint256 received, uint256 bound, uint256 minOut) private pure {
        uint256 required = bound > minOut ? bound : minOut;
        if (received < required) revert PriceBound(received, required);
    }

    function _ethHoldings() private view returns (uint256) {
        return address(this).balance + weth.balanceOf(address(this));
    }

    /// The balance of `token` not owed to claims: 0 while the balance is below totalClaims, all
    /// of which then belongs to the claims. readable is false (and amount 0) when the balance
    /// cannot be read.
    function _available(address token) private view returns (bool readable, uint256 amount) {
        uint256 balance;
        (readable, balance) = _balanceOf(token);
        uint256 owed = totalClaims[token];
        if (balance > owed) amount = balance - owed;
    }

    /// `asset`'s balance here, read with the same BALANCE_GAS cap redemption uses. Reverts
    /// UnreadableAsset when it cannot be read, so a buy can never add to a holding that
    /// redemption would then silently skip, and a claim never pays without knowing whether the
    /// claims are short.
    function _assetBalance(address asset) private view returns (uint256 amount) {
        bool ok;
        (ok, amount) = _balanceOf(asset);
        if (!ok) revert UnreadableAsset(asset);
    }

    /// This contract's balance of `token`, read with at most BALANCE_GAS. ok is false when the
    /// call reverts, runs out of gas or answers with less than 32 bytes; only the first 32
    /// bytes of an answer are copied.
    function _balanceOf(address token) private view returns (bool ok, uint256 amount) {
        bytes memory data = abi.encodeCall(IERC20.balanceOf, (address(this)));
        uint256 gasLimit = BALANCE_GAS;
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, token, add(data, 0x20), mload(data), 0x00, 0x20)
            ok := and(ok, gt(returndatasize(), 0x1f))
            if ok { amount := mload(0x00) }
        }
    }

    /// Sends `amount` of `token` with at most TRANSFER_GAS. Succeeds when the call succeeds and
    /// answers true, or answers nothing from an address that holds code.
    function _tryTransfer(address token, address to, uint256 amount) private returns (bool ok) {
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        uint256 gasLimit = TRANSFER_GAS;
        assembly ("memory-safe") {
            ok := call(gasLimit, token, 0, add(data, 0x20), mload(data), 0x00, 0x20)
            let size := returndatasize()
            let answeredTrue := and(gt(size, 0x1f), eq(mload(0x00), 1))
            let answeredNothing := and(iszero(size), gt(extcodesize(token), 0))
            ok := and(ok, or(answeredTrue, answeredNothing))
        }
    }

    /// USD value (18 decimals) of `amount` at the feed's last published answer, whatever its age,
    /// and the answer's update time. ok is false when the answer cannot be read or the value
    /// does not fit in 256 bits.
    function _tryValue(uint256 amount, address feed, uint8 feedDecimals)
        private
        view
        returns (bool ok, uint256 value, uint256 updatedAt)
    {
        uint256 price;
        (ok, price, updatedAt) = PriceLib.tryLatest(feed, feedDecimals);
        if (ok) (ok, value) = Math.tryMul(amount, price);
        value /= 1e18;
    }
}
