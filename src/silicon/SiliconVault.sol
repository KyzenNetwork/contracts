// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {ISiliconSynth} from "./interfaces/ISiliconSynth.sol";
import {ISiliconFeed} from "./interfaces/ISiliconFeed.sol";
import {IKyznUsdOracle} from "./interfaces/IKyznUsdOracle.sol";

/// @title Kyzen Network Silicon vault (SPEC 3.5)
/// @notice Collateral positions for the Silicon synthetics. Per market, each account holds $KYZN
/// and USDG as collateral and owes a debt in that market's synth.
///
/// Health: collateral value at least 150% of debt value; after a mint or a withdrawal, $KYZN at
/// least 50% of collateral value. $KYZN is valued by KyznUsdOracle (pool TWAP times Chainlink
/// ETH/USD), USDG at $1.00, the synth by its market's SiliconFeed. How fresh the prices must be
/// depends on the action: mint and a withdrawal with debt need the feed's isFresh(), startAuction
/// and the restart of an unsold auction its isFreshForLiquidation(), which a feed may hold longer
/// than isFresh() so that a position can be liquidated while mints are closed; deposit and repay
/// never read a price, so they always work.
/// Mint and withdraw value the synth at the higher of its final price and a price still in its
/// dispute window, so a rise already posted cannot be borrowed against at the old price;
/// startAuction and the restart use the final price only, so a price no one has had the chance to
/// dispute never liquidates.
///
/// Fees are synth minted to the fee router: the mint fee at each mint, the borrow fee every
/// second. Debt is held as shares of the market's total debt; the borrow fee raises the total,
/// so the debt per share is the market's rate index. drip() mints the fee accrued since the last
/// drip; anyone may call it, and mint, repay, startAuction, a withdrawal with debt and a
/// borrow-fee change call it first. Every synth in circulation is therefore owed by a
/// position, by a running auction, or is recorded as the market's bad debt: a market's synth
/// supply always equals totalDebt + auctionDebt + badDebt.
///
/// Liquidation is a Dutch auction. Anyone may start one for a position below 150%: its
/// collateral and debt move into the auction, plus the liquidation penalty. The collateral is
/// offered at a price that starts at its oracle value plus the starting premium and falls
/// linearly to the floor, a share of its oracle value, over the auction's duration; any bidder
/// pays synth and takes collateral at the current price, in part or in whole. Bids repay the
/// debt first (burned), then the penalty (to the auction's fee router). Once both are covered
/// the auction closes and the collateral left returns to the position. If the collateral runs
/// out first, the debt left is the market's bad debt. An auction keeps the terms it started
/// with: the starting premium, floor, duration and fee router in force at startAuction hold for
/// it to the end, through its restart. An auction that ends unsold with debt left restarts once,
/// in place, before any bad debt: closeAuction gives it the same collateral, debt, penalty and
/// terms at the prices of the moment it restarts (new start and floor prices, a new clock), and
/// waits, reverting StalePrice, while those prices are not fresh enough to liquidate on (a feed
/// that never turns fresh again is replaced through queueFeed). When an auction ends again, or
/// ends with its debt repaid, closeAuction closes it: with the debt repaid, the collateral left
/// returns to the position (the penalty no bid covered is waived); otherwise it goes to the
/// auction's fee router, the debt left becoming bad debt.
///
/// Each market has a minimum debt, an owner setting in synth units: a mint or a part payment may
/// not leave a position's debt above zero and below it (SPEC 3.5). A full repay always works, so
/// a minimum raised later strands no one.
///
/// Every level (fees, penalty, debt ceiling, minimum debt, auction duration, premium and floor,
/// fee router) is an owner setting with no default, and a market opens only once all are set and
/// its feed says it is ready (a SiliconFeed is ready once it has a reporter, a guardian and a
/// published methodology) (SPEC 3.5: levels decided before Gen 2; SPEC 3.7: methodology before
/// markets open).
///
/// The settings that bear on positions already open wait in public once a position can exist: a
/// market's borrow fee, liquidation penalty and feed once that market is open, and the auction
/// duration, starting premium, floor and fee router (vault-wide) once any market is open. The
/// owner's setter then queues the change (SettingQueued); anyone applies it SETTING_DELAY (24
/// hours) later, the protocol's public delay, as for the Reserve's targets; the owner or the
/// guardian may cancel it. Until it applies the value in force stays, so a borrower can repay
/// and leave first, and a change never reaches an auction already started. Before that point
/// these setters apply at once. The mint fee, the debt
/// ceiling, the minimum debt and the mint pause always apply at once: the first two bear only on
/// new mints, and a raised minimum is checked only when a position's owner mints or repays in
/// part.
contract SiliconVault is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------- constants

    /// 100%, in basis points.
    uint256 public constant BPS = 10_000;
    /// Collateral value must be at least 150% of debt value (SPEC 3.5).
    uint256 public constant COLLATERAL_RATIO_BPS = 15_000;
    /// After a mint or a withdrawal, $KYZN must be at least 50% of collateral value (SPEC 3.5).
    uint256 public constant MIN_KYZN_SHARE_BPS = 5_000;
    /// The year the borrow fee is quoted over.
    uint256 public constant YEAR = 365 days;
    /// Seconds a queued setting waits before anyone may apply it: the protocol's public delay.
    uint256 public constant SETTING_DELAY = 24 hours;
    uint256 private constant WAD = 1e18;

    /// Settings bits, as unsetSettings() and SettingsUnset report them. Per market:
    uint16 public constant SETTING_MINT_FEE = 1;
    /// Per market.
    uint16 public constant SETTING_BORROW_FEE = 2;
    /// Per market.
    uint16 public constant SETTING_LIQUIDATION_PENALTY = 4;
    /// Per market.
    uint16 public constant SETTING_DEBT_CEILING = 8;
    /// Vault-wide.
    uint16 public constant SETTING_AUCTION_DURATION = 16;
    /// Vault-wide.
    uint16 public constant SETTING_AUCTION_START_PREMIUM = 32;
    /// Vault-wide.
    uint16 public constant SETTING_FEE_ROUTER = 64;
    /// Per market, read from its feed: set while the feed is ready.
    uint16 public constant SETTING_FEED = 128;
    /// Vault-wide.
    uint16 public constant SETTING_AUCTION_FLOOR = 256;
    /// Per market.
    uint16 public constant SETTING_MIN_DEBT = 512;
    /// Every setting a market needs to open.
    uint16 public constant ALL_SETTINGS = 1023;

    // ---------------------------------------------------------------- types

    /// A synth market: its token and feed, the owner's settings for it, and its debt.
    struct Market {
        ISiliconSynth synth;
        ISiliconFeed feed;
        bool open;
        bool mintsPaused;
        uint16 settings; // the per-market SETTING_ bits the owner has set
        uint256 mintFeeBps;
        uint256 borrowFeeBpsPerYear;
        uint256 liquidationPenaltyBps;
        uint256 debtCeiling;
        uint256 lastDrip;
        uint256 totalDebt; // synth owed by positions, fees included
        uint256 totalShares; // debt shares of all positions
        uint256 auctionDebt; // synth owed by running auctions
        uint256 badDebt; // synth owed by no one, left by auctions that fell short
        uint256 minDebt; // least synth a position may owe, other than nothing
    }

    /// One account's collateral and debt in one market.
    struct Position {
        uint256 kyzn;
        uint256 usdg;
        uint256 debtShares;
    }

    /// A running Dutch auction. Start and floor prices are in synth per 1e18 units of the
    /// collateral token, the start with the starting premium included; the price of what is left
    /// falls linearly from the start to the floor over the duration. `restarted` is set once the
    /// auction has begun again, at fresh prices, after ending unsold. The duration, the fee router,
    /// the starting premium and the floor are those in force at startAuction: an auction keeps the
    /// terms it started with, through its restart.
    struct Auction {
        address account;
        uint256 marketId;
        uint256 kyzn;
        uint256 usdg;
        uint256 debt; // synth still to burn
        uint256 penalty; // synth still due to the fee router
        uint256 kyznStartPrice;
        uint256 usdgStartPrice;
        uint256 startedAt;
        uint256 duration;
        uint256 kyznFloorPrice;
        uint256 usdgFloorPrice;
        bool restarted;
        address feeRouter; // receives the penalty and, after a shortfall, the collateral left
        uint16 startPremiumBps;
        uint16 floorBps;
    }

    /// A setting change waiting out SETTING_DELAY. A fee router or a feed is held as its address.
    struct PendingSetting {
        uint256 value;
        uint256 effectiveAt; // 0 when nothing is queued
    }

    // ---------------------------------------------------------------- state

    /// $KYZN, collateral valued by the oracle.
    IERC20 public immutable kyzn;
    /// USDG, collateral valued at $1.00.
    IERC20 public immutable usdg;
    /// $KYZN in USD (pool TWAP times Chainlink ETH/USD).
    IKyznUsdOracle public immutable oracle;
    /// Multiplier from USDG units to 18-decimal USD (USDG is valued at $1.00).
    uint256 public immutable usdgScale;

    /// Where fee synth is minted.
    address public feeRouter;
    /// Seconds an auction's price takes to fall from its start to its floor.
    uint256 public auctionDuration;
    /// How far above the oracle value an auction's price starts.
    uint256 public auctionStartPremiumBps;
    /// The share of the oracle value an auction's price falls to and stays at until it ends.
    uint256 public auctionFloorBps;
    /// The vault-wide SETTING_ bits the owner has set.
    uint16 public vaultSettings;
    /// The address that may cancel a queued setting, as the owner may (none until the owner
    /// names one).
    address public guardian;
    /// Markets opened so far (a market never closes). While it is 0 the vault-wide settings apply
    /// at once.
    uint256 public openMarketCount;
    /// The change queued for each setting, by SETTING_ bit and market id (0 for a vault-wide
    /// setting).
    mapping(uint16 setting => mapping(uint256 id => PendingSetting)) public pendingSettings;

    /// Markets added so far; ids run from 0.
    uint256 public marketCount;
    mapping(uint256 id => Market) private _markets;
    /// Whether a synth already belongs to a market.
    mapping(address synth => bool) public synthListed;
    /// Each account's collateral and debt shares, per market.
    mapping(uint256 id => mapping(address account => Position)) public positions;
    /// Auctions started so far; ids run from 0.
    uint256 public auctionCount;
    mapping(uint256 auctionId => Auction) private _auctions; // a closed auction is deleted

    // ---------------------------------------------------------------- events

    /// A closed market was added for `synth`, priced by `feed`.
    event MarketAdded(uint256 indexed id, address indexed synth, address indexed feed);
    /// The owner set a market's mint fee.
    event MintFeeSet(uint256 indexed id, uint256 bps);
    /// A market's borrow fee per year took effect (set at once, or a queued change applied).
    event BorrowFeeSet(uint256 indexed id, uint256 bpsPerYear);
    /// A market's liquidation penalty took effect (set at once, or a queued change applied).
    event LiquidationPenaltySet(uint256 indexed id, uint256 bps);
    /// The owner set a market's debt ceiling.
    event DebtCeilingSet(uint256 indexed id, uint256 amount);
    /// The owner set a market's minimum debt per position.
    event MinDebtSet(uint256 indexed id, uint256 amount);
    /// The auction duration took effect (set at once, or a queued change applied).
    event AuctionDurationSet(uint256 duration);
    /// The auction starting premium took effect (set at once, or a queued change applied).
    event AuctionStartPremiumSet(uint256 bps);
    /// The auction floor took effect (set at once, or a queued change applied).
    event AuctionFloorSet(uint256 bps);
    /// The fee router took effect (set at once, or a queued change applied).
    event FeeRouterSet(address indexed feeRouter);
    /// A market's feed took effect (set at once on a market not yet open, or a queued change
    /// applied).
    event FeedSet(uint256 indexed id, address indexed feed);
    /// The owner named the guardian (zero: none).
    event GuardianSet(address indexed guardian);
    /// The owner queued `value` for `setting` (of market `id`, or 0 for a vault-wide setting);
    /// anyone may apply it from `effectiveAt`. A fee router or a feed is its address as a number.
    event SettingQueued(uint16 indexed setting, uint256 indexed id, uint256 value, uint256 effectiveAt);
    /// A queued setting took effect.
    event SettingApplied(uint16 indexed setting, uint256 indexed id, uint256 value);
    /// The owner or the guardian dropped a queued setting; the value in force stays.
    event SettingCancelled(uint16 indexed setting, uint256 indexed id);
    /// A market opened.
    event MarketOpened(uint256 indexed id);
    /// The owner paused a market's mints.
    event MintsPaused(uint256 indexed id);
    /// The owner allowed a market's mints again.
    event MintsUnpaused(uint256 indexed id);

    /// Collateral arrived in a position (the amounts received).
    event Deposited(uint256 indexed id, address indexed account, uint256 kyzn, uint256 usdg);
    /// Collateral left a position.
    event Withdrawn(uint256 indexed id, address indexed account, uint256 kyzn, uint256 usdg);
    /// `amount` went to the account; `fee` (the mint fee) to the fee router. Both are now debt.
    event Minted(uint256 indexed id, address indexed account, uint256 amount, uint256 fee);
    /// Synth burned against a position's debt.
    event Repaid(uint256 indexed id, address indexed account, uint256 amount);
    /// Borrow fee accrued since the last drip, minted to the fee router.
    event FeesAccrued(uint256 indexed id, uint256 fee);

    /// A position's collateral and debt moved into an auction, the penalty added.
    event AuctionStarted(
        uint256 indexed auctionId,
        uint256 indexed id,
        address indexed account,
        uint256 kyzn,
        uint256 usdg,
        uint256 debt,
        uint256 penalty
    );
    /// A bidder paid synth for collateral.
    event AuctionBid(uint256 indexed auctionId, address indexed bidder, uint256 paid, uint256 kyzn, uint256 usdg);
    /// The auction is over. `recipient` received the collateral left: the position (credited, when
    /// the debt was repaid) or the fee router (when it was not). `badDebt` is the debt no bid
    /// covered.
    event AuctionClosed(
        uint256 indexed auctionId, address indexed recipient, uint256 kyzn, uint256 usdg, uint256 badDebt
    );
    /// An auction ended unsold with debt left and started again, once, at fresh prices.
    event AuctionRestarted(uint256 indexed auctionId, uint256 kyznStartPrice, uint256 usdgStartPrice);
    /// An auction closed short: `amount` of debt is now owed by no one.
    event BadDebtRecorded(uint256 indexed id, uint256 indexed auctionId, uint256 amount);
    /// Synth burned against the market's bad debt.
    event BadDebtCovered(uint256 indexed id, address indexed account, uint256 amount);

    // ---------------------------------------------------------------- errors

    /// An address is zero.
    error ZeroAddress();
    /// An amount is zero.
    error ZeroAmount();
    /// USDG has more than 18 decimals, or $KYZN and USDG are the same token.
    error BadCollateral();
    /// The synth does not name this vault, or already belongs to a market.
    error BadSynth();
    /// No market has this id.
    error UnknownMarket(uint256 id);
    /// The market has not opened.
    error MarketNotOpen(uint256 id);
    /// The market is already open.
    error MarketAlreadyOpen(uint256 id);
    /// The market cannot open: `unset` holds the SETTING_ bits not yet set.
    error SettingsUnset(uint256 id, uint16 unset);
    /// A fee, penalty or premium above 100%.
    error BpsAboveMaximum(uint256 bps, uint256 maximum);
    /// The auction duration is zero.
    error BadDuration();
    /// The owner has paused this market's mints.
    error MintingPaused(uint256 id);
    /// The mint would take the market's synth outstanding to `debtAfter`, above the ceiling.
    error DebtCeilingExceeded(uint256 debtAfter, uint256 ceiling);
    /// The mint or part payment would leave the position owing `debt`, above zero and below the
    /// market's minimum.
    error DebtBelowMinimum(uint256 debt, uint256 minimum);
    /// "Collateral ratio 148%. Minimum is 150%." (SPEC 5.4), in basis points.
    error CollateralRatioTooLow(uint256 ratioBps, uint256 minimumBps);
    /// $KYZN would be below 50% of the collateral value, in basis points.
    error KyznShareTooLow(uint256 shareBps, uint256 minimumBps);
    /// The withdrawal asks for more $KYZN than the position holds.
    error InsufficientKyzn(uint256 deposited, uint256 requested);
    /// The withdrawal asks for more USDG than the position holds.
    error InsufficientUsdg(uint256 deposited, uint256 requested);
    /// The market's feed has no price fresh enough for this action.
    error StalePrice(address feed);
    /// The position owes nothing.
    error NoDebt();
    /// The position is at or above 150% and cannot be auctioned.
    error NotLiquidatable(uint256 ratioBps, uint256 minimumBps);
    /// No running auction has this id (never started, or closed).
    error AuctionNotActive(uint256 auctionId);
    /// The auction's duration has passed; it can only be closed.
    error AuctionEnded(uint256 auctionId);
    /// The auction runs until `endsAt`.
    error AuctionNotEnded(uint256 auctionId, uint256 endsAt);
    /// The market has no bad debt.
    error NoBadDebt(uint256 id);
    /// Nothing is queued for `setting` (of market `id`, or 0 for a vault-wide setting).
    error NothingQueued(uint16 setting, uint256 id);
    /// The queued setting cannot be applied before `effectiveAt`.
    error SettingNotDue(uint16 setting, uint256 id, uint256 effectiveAt);
    /// The caller is neither the owner nor the guardian.
    error NotOwnerOrGuardian();
    /// The queued feed is not ready to back an open market; the change waits until it is.
    error FeedNotReady(address feed);
    /// The market's feed prices the synth at zero.
    error ZeroPrice(address feed);

    // ---------------------------------------------------------------- constructor

    /// $KYZN (18 decimals), USDG (at most 18 decimals, valued at $1.00) and the $KYZN oracle.
    constructor(IERC20 kyzn_, IERC20 usdg_, IKyznUsdOracle oracle_) Ownable(msg.sender) {
        if (address(kyzn_) == address(0) || address(usdg_) == address(0) || address(oracle_) == address(0)) {
            revert ZeroAddress();
        }
        if (address(kyzn_) == address(usdg_)) revert BadCollateral();
        uint8 d = IERC20Metadata(address(usdg_)).decimals();
        if (d > 18) revert BadCollateral();
        kyzn = kyzn_;
        usdg = usdg_;
        oracle = oracle_;
        usdgScale = 10 ** (18 - d);
    }

    // ---------------------------------------------------------------- owner: markets

    /// Adds a closed market for `synth`, priced by `feed`. The synth must name this vault.
    function addMarket(ISiliconSynth synth, ISiliconFeed feed) external onlyOwner returns (uint256 id) {
        if (address(synth) == address(0) || address(feed) == address(0)) revert ZeroAddress();
        if (synth.vault() != address(this) || synthListed[address(synth)]) revert BadSynth();
        synthListed[address(synth)] = true;
        id = marketCount++;
        Market storage m = _markets[id];
        m.synth = synth;
        m.feed = feed;
        emit MarketAdded(id, address(synth), address(feed));
    }

    /// The mint fee, charged on each mint as a share of the amount minted.
    function setMintFee(uint256 id, uint256 bps) external onlyOwner {
        _checkBps(bps);
        Market storage m = _market(id);
        m.mintFeeBps = bps;
        m.settings |= SETTING_MINT_FEE;
        emit MintFeeSet(id, bps);
    }

    /// The borrow fee per year on debt, accrued every second. It takes effect at once while the
    /// market is not open; once it is open, it is queued and takes effect when applied, at least
    /// SETTING_DELAY later (applySetting). The old rate applies up to the moment it takes effect.
    function setBorrowFee(uint256 id, uint256 bpsPerYear) external onlyOwner {
        _checkBps(bpsPerYear);
        _setOrQueue(SETTING_BORROW_FEE, id, _market(id).open, bpsPerYear);
    }

    /// The liquidation penalty, added to the debt of each auction started once it takes effect:
    /// at once while the market is not open, when applied at least SETTING_DELAY later once it is.
    function setLiquidationPenalty(uint256 id, uint256 bps) external onlyOwner {
        _checkBps(bps);
        _setOrQueue(SETTING_LIQUIDATION_PENALTY, id, _market(id).open, bps);
    }

    /// The market's price feed. While the market is not open it is set at once, as addMarket sets
    /// it (openMarket then needs it ready). Once the market is open it is queued, and applyFeed
    /// takes it at least SETTING_DELAY later, only while it is ready: the way to replace a feed
    /// that has stopped for good, on which an ended auction would otherwise wait for ever.
    function queueFeed(uint256 id, ISiliconFeed feed) external onlyOwner {
        if (address(feed) == address(0)) revert ZeroAddress();
        _setOrQueue(SETTING_FEED, id, _market(id).open, uint160(address(feed)));
    }

    /// The most synth the market may have outstanding after a mint. Accrued fees may pass it;
    /// they only stop further mints.
    function setDebtCeiling(uint256 id, uint256 amount) external onlyOwner {
        Market storage m = _market(id);
        m.debtCeiling = amount;
        m.settings |= SETTING_DEBT_CEILING;
        emit DebtCeilingSet(id, amount);
    }

    /// The least synth a position may owe once it owes anything: a mint or a part payment may not
    /// leave a position's debt above zero and below it, in synth units so that repaying reads no
    /// price. Raising it later strands no one: a position under the new minimum can still repay in
    /// full, or mint up to above it.
    function setMinDebt(uint256 id, uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        Market storage m = _market(id);
        m.minDebt = amount;
        m.settings |= SETTING_MIN_DEBT;
        emit MinDebtSet(id, amount);
    }

    /// Opens a market once every setting is set (SettingsUnset lists those that are not).
    function openMarket(uint256 id) external onlyOwner {
        Market storage m = _market(id);
        if (m.open) revert MarketAlreadyOpen(id);
        uint16 unset = unsetSettings(id);
        if (unset != 0) revert SettingsUnset(id, unset);
        m.open = true;
        m.lastDrip = block.timestamp;
        ++openMarketCount;
        emit MarketOpened(id);
    }

    /// Stops new mints in a market (a USDG depeg, a feed incident). Repay, deposit, withdraw and
    /// auctions continue.
    function pauseMints(uint256 id) external onlyOwner {
        _market(id).mintsPaused = true;
        emit MintsPaused(id);
    }

    /// Allows mints again.
    function unpauseMints(uint256 id) external onlyOwner {
        _market(id).mintsPaused = false;
        emit MintsUnpaused(id);
    }

    // ---------------------------------------------------------------- owner: vault-wide
    // Each takes effect at once while no market is open; once one is, it is queued and takes
    // effect when applied, at least SETTING_DELAY later (applySetting, with id 0).

    /// Seconds an auction's price takes to fall to its floor; applies to auctions started once it
    /// takes effect (an auction keeps its own through its restart).
    function setAuctionDuration(uint256 duration) external onlyOwner {
        if (duration == 0) revert BadDuration();
        _setOrQueue(SETTING_AUCTION_DURATION, 0, openMarketCount != 0, duration);
    }

    /// How far above the oracle value an auction starts; applies to auctions started once it
    /// takes effect (an auction keeps its own through its restart).
    function setAuctionStartPremium(uint256 bps) external onlyOwner {
        _checkBps(bps);
        _setOrQueue(SETTING_AUCTION_START_PREMIUM, 0, openMarketCount != 0, bps);
    }

    /// The share of the oracle value an auction's price falls to, in basis points: above 0 and
    /// below 100%. Applies to auctions started once it takes effect (an auction keeps its own
    /// through its restart).
    function setAuctionFloor(uint256 bps) external onlyOwner {
        if (bps == 0) revert ZeroAmount();
        if (bps >= BPS) revert BpsAboveMaximum(bps, BPS - 1);
        _setOrQueue(SETTING_AUCTION_FLOOR, 0, openMarketCount != 0, bps);
    }

    /// Where fee synth goes once it takes effect. An auction started from then on sends its
    /// penalty, and the collateral left after a shortfall, there too; one started before keeps the
    /// router it started with.
    function setFeeRouter(address feeRouter_) external onlyOwner {
        if (feeRouter_ == address(0)) revert ZeroAddress();
        _setOrQueue(SETTING_FEE_ROUTER, 0, openMarketCount != 0, uint160(feeRouter_));
    }

    // ---------------------------------------------------------------- queued settings

    /// Owner only. Names the guardian, who may cancel a queued setting; zero leaves only the owner.
    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// Anyone, once a queued setting is due: makes it the value in force. `id` is the market for a
    /// market's own setting (borrow fee, liquidation penalty, feed) and 0 for a vault-wide one. A
    /// borrow fee drips the old rate first; a feed must be ready, or this reverts FeedNotReady and
    /// the change stays queued.
    function applySetting(uint16 setting, uint256 id) public nonReentrant {
        PendingSetting memory p = pendingSettings[setting][id];
        if (p.effectiveAt == 0) revert NothingQueued(setting, id);
        if (block.timestamp < p.effectiveAt) revert SettingNotDue(setting, id, p.effectiveAt);
        // A queued feed was an address, so the value fits in 160 bits.
        if (setting == SETTING_FEED && !ISiliconFeed(address(uint160(p.value))).ready()) {
            revert FeedNotReady(address(uint160(p.value)));
        }
        delete pendingSettings[setting][id];
        _write(setting, id, p.value);
        emit SettingApplied(setting, id, p.value);
    }

    /// Anyone, once a queued feed is due and ready: applySetting(SETTING_FEED, id).
    function applyFeed(uint256 id) external {
        applySetting(SETTING_FEED, id);
    }

    /// Owner or guardian: drops a queued setting; the value in force stays.
    function cancelSetting(uint16 setting, uint256 id) external {
        if (msg.sender != owner() && (msg.sender != guardian || guardian == address(0))) {
            revert NotOwnerOrGuardian();
        }
        if (pendingSettings[setting][id].effectiveAt == 0) revert NothingQueued(setting, id);
        delete pendingSettings[setting][id];
        emit SettingCancelled(setting, id);
    }

    // ---------------------------------------------------------------- positions

    /// Adds collateral to the caller's position. Reads no price, so it works at any time while
    /// the market is open.
    function deposit(uint256 id, uint256 kyznAmount, uint256 usdgAmount) external nonReentrant {
        if (kyznAmount == 0 && usdgAmount == 0) revert ZeroAmount();
        if (!_market(id).open) revert MarketNotOpen(id);
        Position storage p = positions[id][msg.sender];
        uint256 kyznIn = _pull(kyzn, kyznAmount);
        uint256 usdgIn = _pull(usdg, usdgAmount);
        p.kyzn += kyznIn;
        p.usdg += usdgIn;
        emit Deposited(id, msg.sender, kyznIn, usdgIn);
    }

    /// Takes collateral out of the caller's position. With debt, the position must stay at or
    /// above 150% with at least 50% $KYZN, at prices fresh by the feed's isFresh(); without debt,
    /// no price is read.
    function withdraw(uint256 id, uint256 kyznAmount, uint256 usdgAmount) external nonReentrant {
        if (kyznAmount == 0 && usdgAmount == 0) revert ZeroAmount();
        Market storage m = _market(id);
        Position storage p = positions[id][msg.sender];
        if (kyznAmount > p.kyzn) revert InsufficientKyzn(p.kyzn, kyznAmount);
        if (usdgAmount > p.usdg) revert InsufficientUsdg(p.usdg, usdgAmount);
        p.kyzn -= kyznAmount;
        p.usdg -= usdgAmount;
        if (p.debtShares != 0) {
            _drip(id, m);
            _checkHealth(m, p);
        }
        _send(kyzn, msg.sender, kyznAmount);
        _send(usdg, msg.sender, usdgAmount);
        emit Withdrawn(id, msg.sender, kyznAmount, usdgAmount);
    }

    /// Mints `amount` synth to the caller against its collateral. The mint fee is minted to the
    /// fee router, and both become the position's debt. Needs an open market with mints not
    /// paused, room under the debt ceiling, prices fresh by the feed's isFresh(), the position's
    /// debt at least the market's minimum afterwards, and the position at or above 150% with at
    /// least 50% $KYZN.
    function mint(uint256 id, uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        Market storage m = _market(id);
        if (!m.open) revert MarketNotOpen(id);
        if (m.mintsPaused) revert MintingPaused(id);
        _drip(id, m);

        uint256 fee = Math.mulDiv(amount, m.mintFeeBps, BPS, Math.Rounding.Ceil);
        uint256 added = amount + fee;
        uint256 debtAfter = m.totalDebt + m.auctionDebt + m.badDebt + added;
        if (debtAfter > m.debtCeiling) revert DebtCeilingExceeded(debtAfter, m.debtCeiling);

        Position storage p = positions[id][msg.sender];
        // The minter's shares round up, so its debt is never less than what it adds.
        uint256 shares = m.totalShares == 0 ? added : Math.mulDiv(added, m.totalShares, m.totalDebt, Math.Rounding.Ceil);
        p.debtShares += shares;
        m.totalShares += shares;
        m.totalDebt += added;
        _checkMinDebt(m, p);
        _checkHealth(m, p);

        m.synth.mint(msg.sender, amount);
        if (fee != 0) m.synth.mint(feeRouter, fee);
        emit Minted(id, msg.sender, amount, fee);
    }

    /// Burns up to `amount` of the caller's synth against its debt; any amount at or above the
    /// debt repays it in full. A part payment may not leave the position owing less than the
    /// market's minimum debt (but something); a full repay always works. Reads no price, so it
    /// works at any time. Returns what was repaid.
    function repay(uint256 id, uint256 amount) external nonReentrant returns (uint256 repaid) {
        if (amount == 0) revert ZeroAmount();
        Market storage m = _market(id);
        _drip(id, m);
        Position storage p = positions[id][msg.sender];
        uint256 shares = p.debtShares;
        if (shares == 0) revert NoDebt();
        uint256 debt = Math.mulDiv(shares, m.totalDebt, m.totalShares);
        if (amount < debt) {
            // A part payment retires its shares rounded down, never more debt than it pays.
            repaid = amount;
            shares = Math.mulDiv(amount, m.totalShares, m.totalDebt);
        } else {
            repaid = debt;
        }
        p.debtShares -= shares;
        m.totalShares -= shares;
        m.totalDebt -= repaid;
        _checkMinDebt(m, p);
        if (repaid != 0) m.synth.burn(msg.sender, repaid);
        emit Repaid(id, msg.sender, repaid);
    }

    /// Anyone: mints the borrow fee accrued since the last drip to the fee router.
    function drip(uint256 id) external nonReentrant {
        _drip(id, _market(id));
    }

    // ---------------------------------------------------------------- liquidation

    /// Anyone: puts a position below 150% up for auction, at prices fresh by the feed's
    /// isFreshForLiquidation(). Its collateral and debt leave the position for the auction, and
    /// the liquidation penalty is added on top. The auction takes the duration, starting premium,
    /// floor and fee router in force now, and keeps them.
    function startAuction(address account, uint256 id) external nonReentrant returns (uint256 auctionId) {
        Market storage m = _market(id);
        _drip(id, m);
        Position memory p = positions[id][account];
        uint256 debt = p.debtShares == 0 ? 0 : Math.mulDiv(p.debtShares, m.totalDebt, m.totalShares);
        if (debt == 0) revert NoDebt();

        (uint256 kyznPrice, uint256 synthPrice) = _freshPrices(m, true);
        uint256 debtUp = Math.mulDiv(p.debtShares, m.totalDebt, m.totalShares, Math.Rounding.Ceil);
        (,, uint256 ratioBps,) = _valuation(p.kyzn, p.usdg, debtUp, kyznPrice, synthPrice);
        if (ratioBps >= COLLATERAL_RATIO_BPS) revert NotLiquidatable(ratioBps, COLLATERAL_RATIO_BPS);

        m.totalDebt -= debt;
        m.totalShares -= p.debtShares;
        m.auctionDebt += debt;
        delete positions[id][account];

        auctionId = auctionCount++;
        Auction storage a = _auctions[auctionId];
        a.account = account;
        a.marketId = id;
        a.kyzn = p.kyzn;
        a.usdg = p.usdg;
        a.debt = debt;
        a.penalty = Math.mulDiv(debt, m.liquidationPenaltyBps, BPS);
        a.duration = auctionDuration;
        a.feeRouter = feeRouter;
        // Both are at most BPS (10,000), checked when set, so they fit in 16 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        a.startPremiumBps = uint16(auctionStartPremiumBps);
        // forge-lint: disable-next-line(unsafe-typecast)
        a.floorBps = uint16(auctionFloorBps);
        _setPrices(a, kyznPrice, synthPrice);
        emit AuctionStarted(auctionId, id, account, p.kyzn, p.usdg, debt, a.penalty);
    }

    /// Pays up to `maxSynth` of the caller's synth for collateral at the current price: never
    /// more than the auction is owed, nor than the price of all its collateral, which a bid at
    /// that price takes whole. A smaller bid takes that share of each collateral token. The debt
    /// is repaid first (burned), then the penalty (minted to the auction's fee router). Closes the
    /// auction once it is owed nothing, or has no collateral left.
    function bid(uint256 auctionId, uint256 maxSynth)
        external
        nonReentrant
        returns (uint256 paid, uint256 kyznOut, uint256 usdgOut)
    {
        if (maxSynth == 0) revert ZeroAmount();
        Auction storage a = _activeAuction(auctionId);
        uint256 lotPrice = _lotPrice(a);
        if (lotPrice == 0) revert AuctionEnded(auctionId);

        paid = Math.min(Math.min(maxSynth, a.debt + a.penalty), lotPrice);
        if (paid == lotPrice) {
            kyznOut = a.kyzn;
            usdgOut = a.usdg;
        } else {
            kyznOut = Math.mulDiv(a.kyzn, paid, lotPrice);
            usdgOut = Math.mulDiv(a.usdg, paid, lotPrice);
        }
        uint256 burned = Math.min(paid, a.debt);
        a.debt -= burned;
        a.penalty -= paid - burned;
        a.kyzn -= kyznOut;
        a.usdg -= usdgOut;
        Market storage m = _markets[a.marketId];
        m.auctionDebt -= burned;

        m.synth.burn(msg.sender, paid);
        if (paid > burned) m.synth.mint(a.feeRouter, paid - burned);
        _send(kyzn, msg.sender, kyznOut);
        _send(usdg, msg.sender, usdgOut);
        emit AuctionBid(auctionId, msg.sender, paid, kyznOut, usdgOut);

        if (a.debt + a.penalty == 0 || (a.kyzn == 0 && a.usdg == 0)) _closeAuction(auctionId, a, m);
    }

    /// Anyone, once an auction's duration has passed. An auction with debt left that has not
    /// restarted restarts, once: the same auction, collateral, debt, penalty and terms (duration,
    /// starting premium, floor, fee router), with new start and floor prices from the oracle and
    /// the feed now and a new start; the feed's price must be fresh by isFreshForLiquidation(), or
    /// this reverts StalePrice and the auction waits for a retry. Otherwise it closes. With the
    /// debt repaid, the collateral left returns to the position and any penalty left is waived;
    /// otherwise the debt left is recorded as the market's bad debt and the collateral left goes
    /// to the auction's fee router. Closing reads no price.
    function closeAuction(uint256 auctionId) external nonReentrant {
        Auction storage a = _activeAuction(auctionId);
        uint256 endsAt = a.startedAt + a.duration;
        if (block.timestamp < endsAt) revert AuctionNotEnded(auctionId, endsAt);
        Market storage m = _markets[a.marketId];
        if (a.debt != 0 && !a.restarted) {
            (uint256 kyznPrice, uint256 synthPrice) = _freshPrices(m, true);
            _setPrices(a, kyznPrice, synthPrice);
            a.restarted = true;
            emit AuctionRestarted(auctionId, a.kyznStartPrice, a.usdgStartPrice);
        } else {
            _closeAuction(auctionId, a, m);
        }
    }

    /// Anyone: burns up to `amount` of the caller's synth against the market's bad debt.
    function coverBadDebt(uint256 id, uint256 amount) external nonReentrant returns (uint256 covered) {
        if (amount == 0) revert ZeroAmount();
        Market storage m = _market(id);
        covered = Math.min(amount, m.badDebt);
        if (covered == 0) revert NoBadDebt(id);
        m.badDebt -= covered;
        m.synth.burn(msg.sender, covered);
        emit BadDebtCovered(id, msg.sender, covered);
    }

    // ---------------------------------------------------------------- views

    /// A market's synth, feed, settings and debt.
    function market(uint256 id) external view returns (Market memory) {
        return _market(id);
    }

    /// A running auction (all zero once closed or never started).
    function auction(uint256 auctionId) external view returns (Auction memory) {
        return _auctions[auctionId];
    }

    /// The SETTING_ bits a market still needs before it can open (0 when it can). SETTING_FEED is
    /// read from the market's feed: it is unset while the feed is not ready.
    function unsetSettings(uint256 id) public view returns (uint16 unset) {
        Market storage m = _market(id);
        unset = ALL_SETTINGS & ~(m.settings | vaultSettings | SETTING_FEED);
        if (!m.feed.ready()) unset |= SETTING_FEED;
    }

    /// What `account` would repay in full now, accrued borrow fee included.
    function debtOf(uint256 id, address account) external view returns (uint256) {
        Market storage m = _market(id);
        uint256 shares = positions[id][account].debtShares;
        if (shares == 0) return 0;
        return Math.mulDiv(shares, m.totalDebt + _accruedFee(m), m.totalShares);
    }

    /// A position's collateral and debt value in USD (18 decimals), its collateral ratio and its
    /// $KYZN share (basis points), at the latest final prices whatever their age (the prices a
    /// liquidation reads), accrued fee included. The ratio is type(uint256).max without debt.
    function health(uint256 id, address account)
        external
        view
        returns (uint256 collateralValue, uint256 debtValue, uint256 ratioBps, uint256 kyznShareBps)
    {
        Market storage m = _market(id);
        Position storage p = positions[id][account];
        uint256 debt = p.debtShares == 0
            ? 0
            : Math.mulDiv(p.debtShares, m.totalDebt + _accruedFee(m), m.totalShares, Math.Rounding.Ceil);
        (uint256 synthPrice,) = m.feed.latestPrice();
        return _valuation(p.kyzn, p.usdg, debt, oracle.price(), synthPrice);
    }

    /// The synth price of all the collateral an auction has left, now (0 once it has ended).
    function auctionPrice(uint256 auctionId) external view returns (uint256) {
        return _lotPrice(_activeAuction(auctionId));
    }

    // ---------------------------------------------------------------- internals

    function _market(uint256 id) private view returns (Market storage) {
        if (id >= marketCount) revert UnknownMarket(id);
        return _markets[id];
    }

    function _activeAuction(uint256 auctionId) private view returns (Auction storage a) {
        a = _auctions[auctionId];
        if (a.account == address(0)) revert AuctionNotActive(auctionId);
    }

    function _checkBps(uint256 bps) private pure {
        if (bps > BPS) revert BpsAboveMaximum(bps, BPS);
    }

    /// Borrow fee accrued on the market's debt since the last drip.
    function _accruedFee(Market storage m) private view returns (uint256) {
        return Math.mulDiv(m.totalDebt, m.borrowFeeBpsPerYear * (block.timestamp - m.lastDrip), BPS * YEAR);
    }

    function _drip(uint256 id, Market storage m) private {
        if (block.timestamp == m.lastDrip) return;
        uint256 fee = _accruedFee(m);
        m.lastDrip = block.timestamp;
        if (fee == 0) return;
        m.totalDebt += fee;
        m.synth.mint(feeRouter, fee);
        emit FeesAccrued(id, fee);
    }

    /// Records a $KYZN observation when one is due and has the feed record the rounds it has
    /// checked (feed.sync()), then reads $KYZN and the synth at prices that must be fresh: by the
    /// feed's isFreshForLiquidation() when `forLiquidation`, by its isFresh() otherwise. Reverts
    /// ZeroPrice when the feed prices the synth at zero (a debt worth nothing cannot be judged,
    /// nor an auction priced).
    function _freshPrices(Market storage m, bool forLiquidation)
        private
        returns (uint256 kyznPrice, uint256 synthPrice)
    {
        oracle.update();
        kyznPrice = oracle.price();
        ISiliconFeed feed = m.feed;
        feed.sync();
        if (!(forLiquidation ? feed.isFreshForLiquidation() : feed.isFresh())) revert StalePrice(address(feed));
        (synthPrice,) = feed.latestPrice();
        if (synthPrice == 0) revert ZeroPrice(address(feed));
    }

    /// Makes `value` the setting in force at once when `queue` is false (no position can feel it
    /// yet); otherwise queues it for SETTING_DELAY, replacing any change already queued for it.
    function _setOrQueue(uint16 setting, uint256 id, bool queue, uint256 value) private {
        if (!queue) return _write(setting, id, value);
        uint256 effectiveAt = block.timestamp + SETTING_DELAY;
        pendingSettings[setting][id] = PendingSetting({value: value, effectiveAt: effectiveAt});
        emit SettingQueued(setting, id, value, effectiveAt);
    }

    /// Puts `value` in force for `setting` (of market `id` for a market's own setting) and marks
    /// it set. A fee router or a feed arrives as its address, so the value fits in 160 bits.
    function _write(uint16 setting, uint256 id, uint256 value) private {
        if (setting == SETTING_BORROW_FEE) {
            Market storage m = _markets[id];
            _drip(id, m); // the old rate up to now
            m.borrowFeeBpsPerYear = value;
            m.settings |= SETTING_BORROW_FEE;
            emit BorrowFeeSet(id, value);
        } else if (setting == SETTING_LIQUIDATION_PENALTY) {
            Market storage m = _markets[id];
            m.liquidationPenaltyBps = value;
            m.settings |= SETTING_LIQUIDATION_PENALTY;
            emit LiquidationPenaltySet(id, value);
        } else if (setting == SETTING_FEED) {
            _markets[id].feed = ISiliconFeed(address(uint160(value)));
            emit FeedSet(id, address(uint160(value)));
        } else {
            if (setting == SETTING_AUCTION_DURATION) {
                auctionDuration = value;
                emit AuctionDurationSet(value);
            } else if (setting == SETTING_AUCTION_START_PREMIUM) {
                auctionStartPremiumBps = value;
                emit AuctionStartPremiumSet(value);
            } else if (setting == SETTING_AUCTION_FLOOR) {
                auctionFloorBps = value;
                emit AuctionFloorSet(value);
            } else {
                feeRouter = address(uint160(value));
                emit FeeRouterSet(feeRouter);
            }
            vaultSettings |= setting;
        }
    }

    /// Reverts when a position that still owes something owes less than the market's minimum debt.
    /// Debt rounds down here, the reverse of the health check: the true debt is then never below
    /// the minimum. A position without debt shares always passes. Reads no price.
    function _checkMinDebt(Market storage m, Position storage p) private view {
        if (p.debtShares == 0) return;
        uint256 debt = Math.mulDiv(p.debtShares, m.totalDebt, m.totalShares);
        if (debt < m.minDebt) revert DebtBelowMinimum(debt, m.minDebt);
    }

    /// Reverts unless a position with debt is at or above 150% with at least 50% $KYZN, at prices
    /// fresh by the feed's isFresh(), the synth at the higher of its final price and any price
    /// still in its dispute window. Debt rounds up here, so a position never passes on rounding.
    function _checkHealth(Market storage m, Position storage p) private {
        if (p.debtShares == 0) return;
        uint256 debt = Math.mulDiv(p.debtShares, m.totalDebt, m.totalShares, Math.Rounding.Ceil);
        (uint256 kyznPrice, uint256 synthPrice) = _freshPrices(m, false);
        (uint256 pending,,,) = m.feed.pendingPrice();
        if (pending > synthPrice) synthPrice = pending;
        (,, uint256 ratioBps, uint256 kyznShareBps) = _valuation(p.kyzn, p.usdg, debt, kyznPrice, synthPrice);
        if (ratioBps < COLLATERAL_RATIO_BPS) revert CollateralRatioTooLow(ratioBps, COLLATERAL_RATIO_BPS);
        if (kyznShareBps < MIN_KYZN_SHARE_BPS) revert KyznShareTooLow(kyznShareBps, MIN_KYZN_SHARE_BPS);
    }

    /// Collateral and debt value in USD (18 decimals; debt rounded up), the collateral ratio and
    /// the $KYZN share of collateral value (basis points, rounded down).
    function _valuation(uint256 kyznAmount, uint256 usdgAmount, uint256 debt, uint256 kyznPrice, uint256 synthPrice)
        private
        view
        returns (uint256 collateralValue, uint256 debtValue, uint256 ratioBps, uint256 kyznShareBps)
    {
        uint256 kyznValue = Math.mulDiv(kyznAmount, kyznPrice, WAD);
        collateralValue = kyznValue + usdgAmount * usdgScale;
        debtValue = Math.mulDiv(debt, synthPrice, WAD, Math.Rounding.Ceil);
        ratioBps = debtValue == 0 ? type(uint256).max : Math.mulDiv(collateralValue, BPS, debtValue);
        kyznShareBps = collateralValue == 0 ? 0 : Math.mulDiv(kyznValue, BPS, collateralValue);
    }

    /// Sets an auction's start and floor prices, in synth per 1e18 units of each collateral
    /// token, from the collateral's oracle value ($KYZN at `kyznPrice` USD, USDG at $1.00, the
    /// synth at `synthPrice` USD): that value times (100% + the auction's starting premium) for
    /// the start, times its floor share for the floor. Starts the clock; the duration is the
    /// auction's own. An auction's start and its restart both set their prices here.
    function _setPrices(Auction storage a, uint256 kyznPrice, uint256 synthPrice) private {
        uint256 start = (BPS + a.startPremiumBps) * WAD;
        uint256 floor = a.floorBps * WAD;
        a.kyznStartPrice = Math.mulDiv(kyznPrice, start, synthPrice * BPS);
        a.usdgStartPrice = Math.mulDiv(usdgScale * WAD, start, synthPrice * BPS);
        a.kyznFloorPrice = Math.mulDiv(kyznPrice, floor, synthPrice * BPS);
        a.usdgFloorPrice = Math.mulDiv(usdgScale * WAD, floor, synthPrice * BPS);
        a.startedAt = block.timestamp;
    }

    /// The synth price of all the collateral an auction has left: the floor, plus the start's
    /// excess over it falling linearly to zero at the end (the whole price is zero from then on).
    /// The start and the floor are each summed over the collateral left and rounded up, against
    /// the bidder; the start is never below the floor, because the floor is below 100%.
    function _lotPrice(Auction storage a) private view returns (uint256) {
        uint256 endsAt = a.startedAt + a.duration;
        if (block.timestamp >= endsAt) return 0;
        uint256 startPrice = Math.mulDiv(a.kyzn, a.kyznStartPrice, WAD, Math.Rounding.Ceil)
            + Math.mulDiv(a.usdg, a.usdgStartPrice, WAD, Math.Rounding.Ceil);
        uint256 floorPrice = Math.mulDiv(a.kyzn, a.kyznFloorPrice, WAD, Math.Rounding.Ceil)
            + Math.mulDiv(a.usdg, a.usdgFloorPrice, WAD, Math.Rounding.Ceil);
        return
            floorPrice + Math.mulDiv(startPrice - floorPrice, endsAt - block.timestamp, a.duration, Math.Rounding.Ceil);
    }

    /// Ends an auction: from bid, once it is owed nothing or has no collateral left, or from
    /// closeAuction after its end. Debt repaid: the collateral left returns to the position, and
    /// any penalty left is waived. Debt left: it becomes bad debt, and the collateral left goes to
    /// the auction's fee router (none is left when a bid took it all).
    function _closeAuction(uint256 auctionId, Auction storage a, Market storage m) private {
        uint256 kyznLeft = a.kyzn;
        uint256 usdgLeft = a.usdg;
        uint256 shortfall = a.debt;
        address account = a.account;
        uint256 id = a.marketId;
        address router = a.feeRouter;
        delete _auctions[auctionId];

        address recipient;
        if (shortfall == 0) {
            recipient = account;
            Position storage p = positions[id][account];
            p.kyzn += kyznLeft;
            p.usdg += usdgLeft;
        } else {
            recipient = router;
            m.auctionDebt -= shortfall;
            m.badDebt += shortfall;
            emit BadDebtRecorded(id, auctionId, shortfall);
            _send(kyzn, recipient, kyznLeft);
            _send(usdg, recipient, usdgLeft);
        }
        emit AuctionClosed(auctionId, recipient, kyznLeft, usdgLeft, shortfall);
    }

    /// Pulls `amount` of `token` from the caller and returns what arrived.
    function _pull(IERC20 token, uint256 amount) private returns (uint256 received) {
        if (amount == 0) return 0;
        uint256 before = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), amount);
        received = token.balanceOf(address(this)) - before;
    }

    function _send(IERC20 token, address to, uint256 amount) private {
        if (amount != 0) token.safeTransfer(to, amount);
    }
}
