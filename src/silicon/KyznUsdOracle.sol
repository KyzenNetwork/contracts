// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";
import {PriceLib} from "../lib/PriceLib.sol";
import {IKyznUsdOracle} from "./interfaces/IKyznUsdOracle.sol";
import {IUniswapV2PairTwap} from "./interfaces/IUniswapV2PairTwap.sol";

/// @title Kyzen Network $KYZN/USD oracle (SPEC 3.5)
/// @notice $KYZN in USD for Silicon collateral: the lower of two time-weighted average prices of
/// the Uniswap v2 $KYZN/WETH pool, a short one and a long one, times Chainlink ETH/USD. Never the
/// pool's spot price, which one transaction can move. Mainnet runs a 1-hour and a 24-hour
/// average; testnet 5 minutes and 30 minutes.
///
/// The averages come from the pool's cumulative price, which Uniswap v2 advances by the price
/// before each block's first trade times the seconds since the last one. A trade moves an average
/// only by its price times the seconds it stands, so a move made and reversed within a block does
/// not move either at all.
///
/// Anyone may call update() to record an observation; one is recorded at most once per short
/// window, and due() says when one would be. A ring keeps the newest
/// 2 x longWindow / shortWindow + 4 observations; with them at least a short window apart, the
/// ring always reaches back two long windows and three short windows from the newest. The short
/// average runs from the newest observation at least one short window old up to now, over one to
/// three short windows; the long average from the newest observation at least one long window
/// old, over one to two long windows. price() takes the lower, so the pessimistic value is what
/// every vault action uses: raising it takes the pool held up for a whole long window, while a
/// fall shows within a short one.
///
/// price() is available one long window after deployment and stays available while
/// observations are at most two short windows apart. A gap of more than three short windows with
/// no observation stops it at once, until an observation recorded after the gap is one short
/// window old. The long average spans up to two long windows so that such a gap, up to one long
/// window, does not stop it again a long window later. A gap of more than one long window also
/// stops the long average, from two long windows after the last observation before the gap
/// until the first one after it is one long window old. SiliconVault calls update() before every
/// priced action, but a call that then reverts undoes its update too, so the observation that
/// ends a gap must come from a direct update() call: the server's worker calls update() every
/// short window, whenever due() is true.
contract KyznUsdOracle is IKyznUsdOracle {
    /// The longest the short average may span, in short windows.
    uint256 public constant MAX_PERIOD_WINDOWS = 3;
    /// The longest the long average may span, in long windows.
    uint256 public constant MAX_LONG_PERIOD_WINDOWS = 2;
    /// The most short windows the long window may hold (24 hours of 15 minutes).
    uint256 public constant MAX_WINDOW_RATIO = 96;
    /// The ETH/USD staleness rule the Reserve and Staking apply (SPEC 3.2).
    uint256 public constant MAX_FEED_AGE = 24 hours;
    uint256 private constant Q112 = 2 ** 112;

    /// A point on the pool's cumulative $KYZN price (WETH per $KYZN, UQ112.112).
    struct Observation {
        uint256 timestamp;
        uint256 cumulative;
    }

    /// The Uniswap v2 $KYZN/WETH pair.
    IUniswapV2PairTwap public immutable pair;
    /// $KYZN (18 decimals), one of the pair's tokens.
    address public immutable kyzn;
    /// WETH (18 decimals), the pair's other token.
    address public immutable weth;
    /// Whether $KYZN is the pair's token0 (then price0Cumulative is WETH per $KYZN).
    bool public immutable kyznIsToken0;
    /// Chainlink ETH/USD.
    address public immutable ethUsdFeed;
    /// The ETH/USD feed's decimals (at most 18), read once at deployment.
    uint8 public immutable ethUsdDecimals;
    /// The short average's shortest span, in seconds, and the least time between observations.
    uint256 public immutable shortWindow;
    /// The long average's shortest span, in seconds: a whole number of short windows, 2 to 96.
    uint256 public immutable longWindow;
    /// How many observations the ring keeps: 2 x longWindow / shortWindow + 4.
    uint256 public immutable ringSize;
    /// The longest span of the short average: MAX_PERIOD_WINDOWS short windows.
    uint256 private immutable _shortMaxPeriod;
    /// The longest span of the long average: MAX_LONG_PERIOD_WINDOWS long windows.
    uint256 private immutable _longMaxPeriod;

    /// The ring of observations: observation number n (from 0, the one made at deployment) is
    /// kept at slot n % ringSize until observation n + ringSize replaces it. Internal, as are
    /// _recorded and _findAtLeast, for the test harness that checks the search against the walk
    /// it replaced.
    mapping(uint256 slot => Observation) internal _ring;
    /// How many observations have been recorded since deployment.
    uint256 internal _recorded;

    /// An observation of the pool's cumulative $KYZN price was recorded.
    event ObservationRecorded(uint256 timestamp, uint256 cumulative);

    /// An address is zero.
    error ZeroAddress();
    /// The windows break a rule: the short window is zero, or the long window is not a whole
    /// number of short windows from 2 to MAX_WINDOW_RATIO.
    error BadWindows(uint256 shortWindow, uint256 longWindow);
    /// $KYZN is not one of the pair's tokens.
    error NotInPair();
    /// $KYZN or WETH does not have 18 decimals.
    error BadDecimals();
    /// The ETH/USD feed has more than 18 decimals.
    error BadFeed();
    /// No observation is old enough for the average yet; the first will be at `readyAt`.
    error TwapNotReady(uint256 readyAt);
    /// The observation to average from, made at `observedAt`, is older than `maxPeriod` seconds.
    error ObservationTooOld(uint256 observedAt, uint256 maxPeriod);
    /// The average rounds to zero.
    error ZeroPrice();
    /// The ring holds no observation at `index` (0 is the newest).
    error NoObservation(uint256 index);

    /// Records the first observation, so the short average works one short window after
    /// deployment and price() one long window after it.
    constructor(
        IUniswapV2PairTwap pair_,
        address kyzn_,
        address ethUsdFeed_,
        uint256 shortWindow_,
        uint256 longWindow_
    ) {
        if (address(pair_) == address(0) || kyzn_ == address(0) || ethUsdFeed_ == address(0)) {
            revert ZeroAddress();
        }
        if (
            shortWindow_ == 0 || longWindow_ % shortWindow_ != 0 || longWindow_ / shortWindow_ < 2
                || longWindow_ / shortWindow_ > MAX_WINDOW_RATIO
        ) revert BadWindows(shortWindow_, longWindow_);
        address token0 = pair_.token0();
        address token1 = pair_.token1();
        if (kyzn_ != token0 && kyzn_ != token1) revert NotInPair();
        address weth_ = kyzn_ == token0 ? token1 : token0;
        if (IERC20Metadata(kyzn_).decimals() != 18 || IERC20Metadata(weth_).decimals() != 18) revert BadDecimals();
        uint8 d = IAggregatorV3(ethUsdFeed_).decimals();
        if (d > 18) revert BadFeed();

        pair = pair_;
        kyzn = kyzn_;
        weth = weth_;
        kyznIsToken0 = kyzn_ == token0;
        ethUsdFeed = ethUsdFeed_;
        ethUsdDecimals = d;
        shortWindow = shortWindow_;
        longWindow = longWindow_;
        ringSize = MAX_LONG_PERIOD_WINDOWS * (longWindow_ / shortWindow_) + 4;
        _shortMaxPeriod = shortWindow_ * MAX_PERIOD_WINDOWS;
        _longMaxPeriod = longWindow_ * MAX_LONG_PERIOD_WINDOWS;

        _record();
    }

    /// Anyone: records an observation if the newest is at least one short window old. Returns
    /// whether it recorded one.
    function update() external returns (bool recorded) {
        if (!due()) return false;
        _record();
        return true;
    }

    /// Whether update() would record an observation now: the newest is at least one short
    /// window old. The worker sends update() only when this is true.
    function due() public view returns (bool) {
        return block.timestamp - _ring[(_recorded - 1) % ringSize].timestamp >= shortWindow;
    }

    /// USD per $KYZN, 18 decimals: the lower of longTwap() and shortTwap() times Chainlink
    /// ETH/USD. Reverts as either average does (the long one checked first), and when the ETH/USD
    /// answer is more than 24 hours old or not positive (PriceLib).
    function price() external view returns (uint256) {
        (uint256 longInEth,) = longTwap();
        (uint256 shortInEth,) = shortTwap();
        uint256 ethUsd = PriceLib.fresh(ethUsdFeed, ethUsdDecimals, MAX_FEED_AGE);
        return Math.mulDiv(Math.min(shortInEth, longInEth), ethUsd, 1e18);
    }

    /// WETH per $KYZN (18 decimals) averaged from the newest observation at least one short
    /// window old up to now, and the seconds averaged over. Reverts TwapNotReady before any
    /// observation is one short window old, and ObservationTooOld when that observation is more
    /// than MAX_PERIOD_WINDOWS short windows old.
    function shortTwap() public view returns (uint256 kyznInEth, uint256 period) {
        return _twap(shortWindow, _shortMaxPeriod);
    }

    /// WETH per $KYZN (18 decimals) averaged from the newest observation at least one long
    /// window old up to now, and the seconds averaged over. Reverts TwapNotReady before any
    /// observation is one long window old, and ObservationTooOld when that observation is more
    /// than MAX_LONG_PERIOD_WINDOWS long windows old.
    function longTwap() public view returns (uint256 kyznInEth, uint256 period) {
        return _twap(longWindow, _longMaxPeriod);
    }

    /// How many observations the ring holds: every one recorded, up to ringSize.
    function observationCount() public view returns (uint256) {
        return Math.min(_recorded, ringSize);
    }

    /// The observation `index` places back from the newest (0 is the newest): when it was made
    /// and the pool's cumulative $KYZN price then. Reverts NoObservation past the oldest held.
    function observation(uint256 index) external view returns (uint256 timestamp, uint256 cumulative) {
        if (index >= observationCount()) revert NoObservation(index);
        Observation storage o = _ring[(_recorded - 1 - index) % ringSize];
        return (o.timestamp, o.cumulative);
    }

    // ---------------------------------------------------------------- internals

    function _record() private {
        uint256 n = _recorded;
        uint256 cumulative = _cumulative();
        _ring[n % ringSize] = Observation({timestamp: block.timestamp, cumulative: cumulative});
        _recorded = n + 1;
        emit ObservationRecorded(block.timestamp, cumulative);
    }

    /// The average from the newest observation at least `age` old up to now, over at most
    /// `maxPeriod` seconds.
    function _twap(uint256 age, uint256 maxPeriod) private view returns (uint256 kyznInEth, uint256 period) {
        Observation memory o = _findAtLeast(age);
        period = block.timestamp - o.timestamp;
        if (period > maxPeriod) revert ObservationTooOld(o.timestamp, maxPeriod);
        uint256 average;
        // Cumulative prices wrap by design (Uniswap v2); the difference is right modulo 2**256.
        unchecked {
            average = (_cumulative() - o.cumulative) / period;
        }
        kyznInEth = Math.mulDiv(average, 1e18, Q112);
        if (kyznInEth == 0) revert ZeroPrice();
    }

    /// The newest observation at least `age` seconds old. Indexed from the newest (0) back, the
    /// held observations' timestamps strictly decrease, so a binary search over the newest
    /// min(recorded, ringSize) finds it; every probe is checked, so the result rests on that order
    /// alone. Reverts TwapNotReady, at the oldest held's timestamp plus `age`, when none is that
    /// old yet; that happens only before the ring is full, since a full ring reaches back two long
    /// windows and three short windows, and then the oldest held is the first to come of age.
    function _findAtLeast(uint256 age) internal view returns (Observation memory) {
        uint256 n = _recorded;
        uint256 size = ringSize;
        // The newest first, as update() has usually just read or written it.
        uint256 lo;
        uint256 loAt = _ring[(n - 1) % size].timestamp;
        if (block.timestamp - loAt >= age) return _ring[(n - 1) % size];
        // From here the observation at lo is younger than `age`, and the one at hi at least that
        // old, or hi is count while none is known to be.
        uint256 count = Math.min(n, size);
        uint256 hi = count;
        // update() keeps observations at least a short window apart, so the answer is at most
        // `guess` places back, and exactly there while they are one short window apart, as the
        // worker keeps them. The search probes the guess first and, when it is old enough, the one
        // before it; then it halves the range.
        uint256 guess = Math.ceilDiv(age - (block.timestamp - loAt), shortWindow);
        uint256 mid = guess < count ? guess : count / 2;
        while (hi - lo > 1) {
            uint256 t = _ring[(n - 1 - mid) % size].timestamp;
            if (block.timestamp - t >= age) hi = mid;
            else (lo, loAt) = (mid, t);
            mid = mid == guess && hi == guess ? guess - 1 : (lo + hi) / 2;
        }
        if (hi == count) revert TwapNotReady(loAt + age);
        return _ring[(n - 1 - hi) % size];
    }

    /// The pool's cumulative $KYZN price as of now, as UniswapV2OracleLibrary computes it: the
    /// stored cumulative plus, when no trade has updated it this second, the price of the
    /// reserves since the last update times the seconds since then. Reserves set in the current
    /// block contribute nothing, because no time has passed since they were set.
    function _cumulative() private view returns (uint256 cumulative) {
        cumulative = kyznIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        (uint112 reserve0, uint112 reserve1, uint32 updatedAt) = pair.getReserves();
        // Uniswap v2 keeps time modulo 2**32; the truncation is intended.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 now32 = uint32(block.timestamp);
        // As in Uniswap v2: elapsed time wraps modulo 2**32 and the cumulative price wraps.
        unchecked {
            uint32 elapsed = now32 - updatedAt;
            if (elapsed != 0 && reserve0 != 0 && reserve1 != 0) {
                uint256 spot =
                    kyznIsToken0 ? (uint256(reserve1) << 112) / reserve0 : (uint256(reserve0) << 112) / reserve1;
                cumulative += spot * elapsed;
            }
        }
    }
}
