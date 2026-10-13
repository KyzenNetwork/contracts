// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {IMarketCalendar} from "./interfaces/IMarketCalendar.sol";
import {ISiliconFeed} from "./interfaces/ISiliconFeed.sol";

/// @title Kyzen Network stock index feed (SPEC 3.5)
/// @notice A Silicon market's USD price (18 decimals): a fixed basket of Robinhood stock tokens
/// valued at their Chainlink feeds. The basket is set at deployment with equal dollar weights so
/// the index starts at 100 USD, and never rebalances. Mints need the calendar's window and every
/// price under 24 hours old; liquidations need every price under 96 hours old.
///
/// The circuit breaker latches. Each component keeps a checked round: the last round accepted, at
/// deployment (the reference price), by sync() after walking the rounds since and finding each
/// within 30% of the one before, or by the guardian's clearJump(). A component whose rounds past
/// the checked one hold a move of more than 30%, a non-positive answer, or a round that cannot be
/// read, stops both mints and liquidations. A later round within 30% of the jump does not release
/// it: only the guardian's clearJump() does, naming the round it checked. A view walks at most
/// MAX_SCAN rounds past the checked one, so a longer backlog stops the feed until sync() (anyone,
/// and the vault before it reads freshness) has caught up.
///
/// A stock split changes no quantity: each component feed's price per token already includes the
/// token's multiplier (SPEC 3.2a), so the index carries on across a split. A quantity changes
/// only as a correction (for example when a component's feed or token is migrated to one that
/// quotes a different amount of the stock), 24 hours after the owner queues it, and the owner or
/// the guardian may cancel it; applying a quantity stops the feed too, until the guardian clears
/// that component, and the guardian cannot clear a component while a quantity is queued for it.
/// So a correction is accepted only once, by a person who has seen the new price against the new
/// quantity. Runbook: queue the corrected quantity so that it falls due before the feed's new
/// basis prints, apply it, then clear the component after the print.
///
/// No reporter and no dispute window: Chainlink is the source. Every read of a component feed is
/// gas-capped and never reverts, and so is the arithmetic on what they answer, so a broken feed or
/// an absurd answer reads as stale (price zero, not fresh, jumped) and never as a revert inside the
/// vault.
contract StockIndexFeed is Ownable2Step, ISiliconFeed {
    /// One stock of the basket: its Chainlink feed and how much of it an index unit holds.
    struct Component {
        address feed;
        uint8 decimals;
        uint256 quantity; // stock units per index unit, 18 decimals
    }

    /// A quantity change waiting out its delay.
    struct Queued {
        uint256 quantity;
        uint256 effectiveAt; // 0 when nothing is queued
    }

    /// Seconds a component's latest answer stays fresh enough to mint against.
    uint256 public constant MINT_MAX_AGE = 24 hours;
    /// Seconds a component's latest answer stays fresh enough to liquidate on.
    uint256 public constant LIQUIDATION_MAX_AGE = 96 hours;
    /// The largest move between two rounds, in basis points of the earlier answer, that is not a jump.
    uint256 public constant JUMP_BPS = 3_000;
    /// Seconds a queued quantity waits before anyone may apply it.
    uint256 public constant QUANTITY_DELAY = 24 hours;
    /// The most components a basket may hold.
    uint256 public constant MAX_COMPONENTS = 4;
    /// The index's price at deployment, in USD (18 decimals).
    uint256 public constant BASE_PRICE = 100e18;
    /// The most rounds past the checked one a single scan walks.
    uint256 public constant MAX_SCAN = 16;
    // Basis points in a whole, and 1 in 18 decimals.
    uint256 private constant BPS = 10_000;
    uint256 private constant WAD = 1e18;
    // Gas for one round read; the same cap as PriceLib's.
    uint256 private constant ROUND_GAS = PriceLib.FEED_GAS;

    /// What the index prices, for example "SEMI-1 / USD".
    string public description;
    /// The calendar that says when mints may use the price.
    IMarketCalendar public immutable calendar;
    /// The address that may pause mints, clear a stopped component and cancel a queued quantity
    /// (none until the owner sets it).
    address public guardian;
    /// True while the guardian has paused mints; liquidations are not paused.
    bool public paused;
    /// Where the published methodology lives (basket, weights, quantity corrections, breaker).
    string public methodologyURI;
    /// Hash of the published methodology document (zero until published).
    bytes32 public methodologyHash;
    // The basket, in the order given at deployment.
    Component[] private _components;
    /// The quantity change waiting for component `i`, if any.
    mapping(uint256 i => Queued) public queued;
    /// The last round of component `i` accepted: at deployment, by sync() over clean rounds, or by
    /// the guardian's clearJump(). Rounds up to it are not measured again.
    mapping(uint256 i => uint80) public checkedRound;
    /// True once a quantity was applied to component `i` and the guardian has not cleared it since.
    mapping(uint256 i => bool) public needsClear;

    /// Component `i` joined the basket at deployment, with `quantity` of the stock per index unit,
    /// its feed on `roundId` as the reference round.
    event ComponentAdded(uint256 indexed i, address feed, uint8 decimals, uint256 quantity, uint80 roundId);
    /// The owner named the guardian (zero: none).
    event GuardianSet(address indexed guardian);
    /// The owner published the methodology's location and hash.
    event MethodologySet(string uri, bytes32 hash);
    /// The owner queued `quantity` for component `i`; anyone may apply it from `effectiveAt`.
    event QuantityQueued(uint256 indexed i, uint256 quantity, uint256 effectiveAt);
    /// A queued quantity became component `i`'s quantity.
    event QuantityApplied(uint256 indexed i, uint256 quantity);
    /// The owner or the guardian cancelled component `i`'s queued quantity.
    event QuantityCancelled(uint256 indexed i);
    /// sync() accepted component `i`'s rounds up to `roundId`, each within the jump limit.
    event RoundChecked(uint256 indexed i, uint80 roundId);
    /// The guardian accepted round `roundId` of component `i`, clearing any stop on it.
    event JumpCleared(uint256 indexed i, uint80 roundId);
    /// The guardian paused mints.
    event Paused();
    /// The guardian resumed mints.
    event Unpaused();

    /// A basket needs one to MAX_COMPONENTS components, each a different feed.
    error BadComponents();
    /// An address that must not be zero is.
    error ZeroAddress();
    /// The feed has more than 18 decimals, cannot be read, answers with a non-positive price, or
    /// is on round 0.
    error BadFeed(address feed);
    /// The caller is not the guardian.
    error NotGuardian();
    /// The caller is neither the owner nor the guardian.
    error NotOwnerOrGuardian();
    /// A quantity must be above zero.
    error BadQuantity();
    /// Component `i` has a quantity queued; the guardian clears it only after the quantity is
    /// applied or cancelled.
    error QuantityPending(uint256 i);
    /// Component `i` has no quantity queued.
    error NoQueuedQuantity(uint256 i);
    /// The queued quantity cannot be applied before `effectiveAt`.
    error QuantityNotDue(uint256 effectiveAt);
    /// There is no component `i`.
    error UnknownComponent(uint256 i);
    /// clearJump named round `expected`, but the feed is on round `current` (or the round is 0).
    error RoundMismatch(uint80 expected, uint80 current);

    /// Only the guardian.
    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    /// Reads each feed's current price and sets equal-dollar quantities (rounded down per
    /// component) so the index starts at 100 USD. Each component's deployment round is accepted:
    /// it is the reference price, and no jump is measured against the round before it. Reverts if
    /// `feeds_` is empty, longer than MAX_COMPONENTS or repeats a feed, if `calendar_` or a feed is
    /// zero, and with BadFeed for a feed that has more than 18 decimals, cannot be read, answers
    /// with a non-positive price or is on round 0.
    constructor(string memory description_, IMarketCalendar calendar_, address[] memory feeds_, address owner_)
        Ownable(owner_)
    {
        uint256 n = feeds_.length;
        if (n == 0 || n > MAX_COMPONENTS) revert BadComponents();
        if (address(calendar_) == address(0)) revert ZeroAddress();
        description = description_;
        calendar = calendar_;
        uint256 share = BASE_PRICE / n;
        for (uint256 i = 0; i < n; i++) {
            if (feeds_[i] == address(0)) revert ZeroAddress();
            for (uint256 j = 0; j < i; j++) {
                if (feeds_[j] == feeds_[i]) revert BadComponents();
            }
            _addComponent(i, feeds_[i], share);
        }
    }

    // ---------------------------------------------------------------- owner and guardian

    /// Owner only. Names the guardian; zero leaves no one to pause, clear or cancel.
    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// Owner only. Publishes the methodology's location and hash (SPEC 3.7: methodology before
    /// markets open).
    function setMethodology(string calldata uri, bytes32 hash) external onlyOwner {
        methodologyURI = uri;
        methodologyHash = hash;
        emit MethodologySet(uri, hash);
    }

    /// Owner only. Queues a corrected quantity for component `i` (a split needs none: the feed's
    /// price includes the multiplier), due QUANTITY_DELAY from now. A second call replaces the
    /// first and restarts the delay.
    function queueQuantity(uint256 i, uint256 quantity) external onlyOwner {
        _componentAt(i);
        if (quantity == 0) revert BadQuantity();
        uint256 effectiveAt = block.timestamp + QUANTITY_DELAY;
        queued[i] = Queued({quantity: quantity, effectiveAt: effectiveAt});
        emit QuantityQueued(i, quantity, effectiveAt);
    }

    /// Anyone, once the queued quantity is due: makes it component `i`'s quantity. The component
    /// then reads as jumped until the guardian clears it, so the feed is stopped until a person
    /// has seen the price against the new quantity.
    function applyQuantity(uint256 i) external {
        Component storage c = _componentAt(i);
        Queued memory q = queued[i];
        if (q.effectiveAt == 0) revert NoQueuedQuantity(i);
        if (block.timestamp < q.effectiveAt) revert QuantityNotDue(q.effectiveAt);
        c.quantity = q.quantity;
        needsClear[i] = true;
        delete queued[i];
        emit QuantityApplied(i, q.quantity);
    }

    /// Owner or guardian: drops component `i`'s queued quantity.
    function cancelQuantity(uint256 i) external {
        if (msg.sender != owner() && msg.sender != guardian) revert NotOwnerOrGuardian();
        if (queued[i].effectiveAt == 0) revert NoQueuedQuantity(i);
        delete queued[i];
        emit QuantityCancelled(i);
    }

    /// Guardian only. Stops mints (liquidations go on).
    function pause() external onlyGuardian {
        paused = true;
        emit Paused();
    }

    /// Guardian only. Resumes mints.
    function unpause() external onlyGuardian {
        paused = false;
        emit Unpaused();
    }

    /// Guardian only. Accepts round `roundId` of component `i` after a jump (a quantity correction
    /// applied, or a print checked): it becomes the checked round and any stop from an applied
    /// quantity ends. Reverts with QuantityPending while a quantity is queued for the component
    /// (apply or cancel it first, so a print on the new basis is never accepted against the old
    /// quantity), with BadFeed when the feed cannot be read, and with RoundMismatch unless
    /// `roundId` is the feed's current round (and not 0), so the guardian clears exactly the round
    /// it checked: a newer print that lands first is not accepted unseen.
    function clearJump(uint256 i, uint80 roundId) external onlyGuardian {
        Component storage c = _componentAt(i);
        if (queued[i].effectiveAt != 0) revert QuantityPending(i);
        (bool ok, uint80 current,) = _tryRound(c.feed, abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!ok) revert BadFeed(c.feed);
        if (roundId == 0 || current != roundId) revert RoundMismatch(roundId, current);
        checkedRound[i] = roundId;
        needsClear[i] = false;
        emit JumpCleared(i, roundId);
    }

    // ---------------------------------------------------------------- ISiliconFeed

    /// @inheritdoc ISiliconFeed
    /// @dev The basket's USD value, each component's value rounded up (against the minter), and
    /// the oldest component update time. (0, 0) when any component cannot be read, has a
    /// non-positive answer or an update time in the future, or a component's quantity * price does
    /// not fit in 256 bits. It does not consult the breaker, the pause or the calendar: isFresh()
    /// and isFreshForLiquidation() do. Never reverts.
    function latestPrice() public view returns (uint256 price, uint256 updatedAt) {
        bool ok;
        (ok, price, updatedAt) = _read();
        if (!ok) return (0, 0);
    }

    /// @inheritdoc ISiliconFeed
    /// @dev Not paused, inside the calendar's window, and every component readable, under
    /// MINT_MAX_AGE old and not stopped by the breaker. False whenever latestPrice() is (0, 0).
    function isFresh() external view returns (bool) {
        return !paused && calendar.isMintWindow(block.timestamp) && _fresh(MINT_MAX_AGE);
    }

    /// @inheritdoc ISiliconFeed
    /// @dev Every component readable, under LIQUIDATION_MAX_AGE old and not stopped by the
    /// breaker, at any hour and while paused. False whenever latestPrice() is (0, 0).
    function isFreshForLiquidation() external view returns (bool) {
        return _fresh(LIQUIDATION_MAX_AGE);
    }

    /// @inheritdoc ISiliconFeed
    /// @dev Always zero: there is no dispute window.
    function pendingPrice() external pure returns (uint256, uint256, bytes32, uint256) {
        return (0, 0, bytes32(0), 0);
    }

    /// @inheritdoc ISiliconFeed
    /// @dev Always zero: Chainlink posts the prices.
    function reporter() external pure returns (address) {
        return address(0);
    }

    /// @inheritdoc ISiliconFeed
    /// @dev The guardian and the methodology are both set.
    function ready() external view returns (bool) {
        return guardian != address(0) && methodologyHash != bytes32(0);
    }

    /// @inheritdoc ISiliconFeed
    /// @dev Anyone. For each component, advances the checked round over the rounds since it that
    /// are each within JUMP_BPS of the one before, at most MAX_SCAN of them per call. It never
    /// moves the checked round backwards and never past a jump, a non-positive answer or a round
    /// it cannot read. Never reverts.
    function sync() external {
        uint256 n = _components.length;
        for (uint256 i = 0; i < n; i++) {
            (, uint80 lastClean) = _scan(i);
            if (lastClean > checkedRound[i]) {
                checkedRound[i] = lastClean;
                emit RoundChecked(i, lastClean);
            }
        }
    }

    // ---------------------------------------------------------------- views

    /// How many components the basket holds.
    function componentCount() external view returns (uint256) {
        return _components.length;
    }

    /// Component `i`: its Chainlink feed, the feed's decimals and the stock units per index unit
    /// (18 decimals). Reverts with UnknownComponent past the last.
    function component(uint256 i) external view returns (address feed, uint8 decimals, uint256 quantity) {
        Component storage c = _componentAt(i);
        return (c.feed, c.decimals, c.quantity);
    }

    /// True when component `i` is stopped: a quantity was applied and the guardian has not cleared
    /// it, or the rounds since its checked round are not all clean (a move of more than JUMP_BPS,
    /// a non-positive answer, a round that cannot be read, round 0, a feed behind its checked
    /// round, or more than MAX_SCAN rounds not yet synced). A jump stays until the guardian clears
    /// it, however clean the later rounds are. Never reverts, except for an unknown component.
    function jumped(uint256 i) public view returns (bool) {
        _componentAt(i);
        if (needsClear[i]) return true;
        (bool clean,) = _scan(i);
        return !clean;
    }

    // ---------------------------------------------------------------- internals

    /// Reads feed `feed_` for the basket at deployment: its decimals, price and current round, and
    /// the quantity that gives it `share` USD of the index.
    function _addComponent(uint256 i, address feed_, uint256 share) private {
        uint8 d = IAggregatorV3(feed_).decimals();
        if (d > 18) revert BadFeed(feed_);
        (bool ok, uint256 price,) = PriceLib.tryLatest(feed_, d);
        if (!ok) revert BadFeed(feed_);
        uint80 roundId;
        (ok, roundId,) = _tryRound(feed_, abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!ok || roundId == 0) revert BadFeed(feed_);
        uint256 quantity = Math.mulDiv(share, WAD, price);
        checkedRound[i] = roundId;
        _components.push(Component({feed: feed_, decimals: d, quantity: quantity}));
        emit ComponentAdded(i, feed_, d, quantity, roundId);
    }

    /// The basket's value and its oldest update time, or ok false when any component cannot be
    /// read, answers non-positive, is dated in the future, or a component's quantity * price
    /// overflows 256 bits. Each value rounds up. The values are each at most 2^256 / 1e18 (about
    /// 1.2e59) once divided, so their sum over at most MAX_COMPONENTS (4) cannot overflow.
    function _read() private view returns (bool ok, uint256 price, uint256 oldest) {
        oldest = type(uint256).max;
        uint256 n = _components.length;
        for (uint256 i = 0; i < n; i++) {
            Component storage c = _components[i];
            uint256 p;
            uint256 t;
            (ok, p, t) = PriceLib.tryLatest(c.feed, c.decimals);
            // An update time in the future is not a real one: unreadable, whatever the others say.
            if (!ok || t > block.timestamp) return (false, 0, 0);
            uint256 value;
            (ok, value) = Math.tryMul(c.quantity, p);
            if (!ok) return (false, 0, 0);
            price += Math.ceilDiv(value, WAD);
            if (t < oldest) oldest = t;
        }
        return (true, price, oldest);
    }

    /// Every component is readable, no older than `maxAge` and not stopped by the breaker.
    function _fresh(uint256 maxAge) private view returns (bool) {
        (bool ok,, uint256 oldest) = _read();
        if (!ok || block.timestamp - oldest > maxAge) return false;
        uint256 n = _components.length;
        for (uint256 i = 0; i < n; i++) {
            if (jumped(i)) return false;
        }
        return true;
    }

    function _componentAt(uint256 i) private view returns (Component storage) {
        if (i >= _components.length) revert UnknownComponent(i);
        return _components[i];
    }

    /// Walks component `i`'s rounds past its checked one, at most MAX_SCAN of them. `clean` is
    /// true when the feed's latest round is reached with every step within JUMP_BPS; `lastClean`
    /// is the last round reached cleanly (the checked round when none, or when the feed cannot be
    /// read, is on round 0 or has gone behind it). Never reverts.
    function _scan(uint256 i) private view returns (bool clean, uint80 lastClean) {
        address feed = _components[i].feed;
        uint80 checked = checkedRound[i];
        (bool ok, uint80 latest,) = _tryRound(feed, abi.encodeCall(IAggregatorV3.latestRoundData, ()));
        if (!ok || latest == 0 || latest < checked) return (false, checked);
        if (latest == checked) return (true, checked);
        int256 previous;
        (ok,, previous) = _tryRound(feed, abi.encodeCall(IAggregatorV3.getRoundData, (checked)));
        if (!ok || previous <= 0) return (false, checked);
        uint80 r = checked;
        for (uint256 steps = 0; r < latest; steps++) {
            if (steps == MAX_SCAN) return (false, r);
            int256 answer;
            (ok,, answer) = _tryRound(feed, abi.encodeCall(IAggregatorV3.getRoundData, (r + 1)));
            if (!ok || answer <= 0 || _moved(previous, answer)) return (false, r);
            previous = answer;
            r++;
        }
        return (true, latest);
    }

    /// True when `current` is more than JUMP_BPS from `previous` (both positive).
    function _moved(int256 previous, int256 current) private pure returns (bool) {
        // Both answers are positive (the callers check), so the casts cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 b = uint256(previous);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 a = uint256(current);
        uint256 diff = a > b ? a - b : b - a;
        // diff * 10_000 > b * 3_000 for whole numbers, without the products that could overflow.
        return diff > Math.mulDiv(b, JUMP_BPS, BPS);
    }

    /// A round's id and answer (latestRoundData or getRoundData, encoded in `data`) through a
    /// gas-capped staticcall that never reverts, decoding by hand as PriceLib.tryLatest does.
    function _tryRound(address feed, bytes memory data) private view returns (bool ok, uint80 roundId, int256 answer) {
        uint256 gasLimit = ROUND_GAS;
        uint256 id;
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, feed, add(data, 0x20), mload(data), 0x00, 0x00)
            ok := and(ok, gt(returndatasize(), 0x9f))
            if ok {
                returndatacopy(0x00, 0x00, 0x40) // roundId and answer: the first two of the five words
                id := mload(0x00)
                answer := mload(0x20)
            }
        }
        if (!ok || id > type(uint80).max) return (false, 0, 0);
        // id fits in uint80, checked above.
        // forge-lint: disable-next-line(unsafe-typecast)
        roundId = uint80(id);
    }
}
