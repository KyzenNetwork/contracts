// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {KyznUsdOracle} from "../../src/silicon/KyznUsdOracle.sol";
import {IUniswapV2PairTwap} from "../../src/silicon/interfaces/IUniswapV2PairTwap.sol";
import {IUniswapV2Factory} from "../../src/interfaces/IUniswapV2.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockFeed} from "../mocks/MockFeed.sol";
import {MockToken} from "./mocks/SiliconMocks.sol";

/// The pair calls these tests make beside what the oracle reads.
interface ITestPair is IUniswapV2PairTwap {
    function mint(address to) external returns (uint256 liquidity);
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
    function sync() external;
}

/// $KYZN/USD at the lower of a short and a long Uniswap v2 TWAP, times Chainlink ETH/USD, on the
/// official Uniswap v2 factory and pair (the unmodified build in external/uniswap-v2, as the
/// launch tests use), offline. Mainnet windows: 1 hour and 24 hours.
/// Pool: 1,000,000 $KYZN and 100 WETH (0.0001 ETH per $KYZN); ETH $2,500; so $KYZN is $0.25.
contract KyznUsdOracleTest is Test {
    uint256 internal constant SHORT = 1 hours;
    uint256 internal constant LONG = 24 hours;
    /// The ring: two long windows of short windows, and four more.
    uint256 internal constant SLOTS = 2 * LONG / SHORT + 4;
    uint256 internal constant START = 1_790_604_000;
    /// ETH/USD at 18 decimals, as the oracle scales the 8-decimal feed.
    uint256 internal constant ETH_USD = 2_500e18;
    uint256 internal constant POOL_KYZN = 1_000_000e18;
    uint256 internal constant POOL_WETH = 100e18;
    uint256 internal constant KYZN_USD = 0.25e18;
    /// UQ112.112 truncation in the pair and the oracle: the price is right to about 1e-12.
    uint256 internal constant PRECISION = 1e6; // relative, in 1e18

    address internal constant KYZN_LOW = address(0x1000); // sorts before WETH: token0
    address internal constant KYZN_HIGH = address(type(uint160).max - 15); // sorts after WETH: token1

    MockWETH internal weth;
    IUniswapV2Factory internal factory;
    MockFeed internal ethUsd;
    MockToken internal kyzn;
    ITestPair internal pair;
    KyznUsdOracle internal oracle;

    /// The observations this test saw the main oracle record, oldest first: when, and the pool's
    /// cumulative price then, computed here from the pair.
    uint256[] internal seenAt;
    uint256[] internal seenCumulative;

    function setUp() public {
        vm.warp(START);
        weth = new MockWETH();
        factory = IUniswapV2Factory(deployCode("external/uniswap-v2/UniswapV2Factory.json", abi.encode(address(this))));
        ethUsd = new MockFeed(8, 2_500e8);
        (kyzn, pair) = _pool(KYZN_LOW);
        oracle = new KyznUsdOracle(pair, address(kyzn), address(ethUsd), SHORT, LONG);
        seenAt.push(block.timestamp);
        seenCumulative.push(_expectedCumulative());
    }

    // ---------------------------------------------------------------- helpers

    /// A $KYZN stand-in at `where`, its pair with WETH, seeded with the pool above.
    function _pool(address where) internal returns (MockToken token, ITestPair p) {
        deployCodeTo("SiliconMocks.sol:MockToken", abi.encode("KYZN", uint8(18)), where);
        token = MockToken(where);
        p = ITestPair(factory.createPair(where, address(weth)));
        token.mint(address(p), POOL_KYZN);
        vm.deal(address(this), address(this).balance + POOL_WETH);
        weth.deposit{value: POOL_WETH}();
        assertTrue(weth.transfer(address(p), POOL_WETH));
        p.mint(address(this));
    }

    function _reserves(ITestPair p, address token) internal view returns (uint256 kyznReserve, uint256 wethReserve) {
        (uint112 r0, uint112 r1,) = p.getReserves();
        (kyznReserve, wethReserve) = p.token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// Spot $KYZN in USD from the reserves, for comparison only.
    function _spotUsd(ITestPair p, address token) internal view returns (uint256) {
        (uint256 k, uint256 w) = _reserves(p, token);
        return w * 2_500e18 / k;
    }

    /// Sells `wethIn` WETH into the pool for $KYZN (raises the $KYZN price).
    function _buyKyzn(ITestPair p, address token, uint256 wethIn) internal {
        (uint256 k, uint256 w) = _reserves(p, token);
        uint256 out = wethIn * 997 * k / (w * 1000 + wethIn * 997);
        vm.deal(address(this), address(this).balance + wethIn);
        weth.deposit{value: wethIn}();
        assertTrue(weth.transfer(address(p), wethIn));
        if (p.token0() == token) p.swap(out, 0, address(this), "");
        else p.swap(0, out, address(this), "");
    }

    /// Sells `kyznIn` $KYZN into the pool for WETH (lowers the $KYZN price).
    function _sellKyzn(ITestPair p, MockToken token, uint256 kyznIn) internal {
        (uint256 k, uint256 w) = _reserves(p, address(token));
        uint256 out = kyznIn * 997 * w / (k * 1000 + kyznIn * 997);
        token.mint(address(p), kyznIn);
        if (p.token0() == address(token)) p.swap(0, out, address(this), "");
        else p.swap(out, 0, address(this), "");
    }

    /// The main pool's cumulative $KYZN price as of now ($KYZN is token0): the stored cumulative
    /// plus the reserves' price times the seconds since the pair's last update, modulo 2**32 as
    /// Uniswap v2 keeps time.
    function _expectedCumulative() internal view returns (uint256 cumulative) {
        (uint112 r0, uint112 r1, uint32 last) = pair.getReserves();
        cumulative = pair.price0CumulativeLast();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 now32 = uint32(block.timestamp);
        unchecked {
            cumulative += (uint256(r1) << 112) / r0 * uint32(now32 - last);
        }
    }

    /// update() on the main oracle, noting here what it records.
    function _update() internal returns (bool recorded) {
        uint256 cumulative = _expectedCumulative();
        recorded = oracle.update();
        if (recorded) {
            seenAt.push(block.timestamp);
            seenCumulative.push(cumulative);
        }
    }

    /// Time passes in steps of one short window (the last may be shorter), with update() on the
    /// main oracle after each, as the worker does; ETH/USD is re-stamped at the end.
    function _advance(uint256 duration) internal {
        _advance(KyznUsdOracle(address(0)), duration);
    }

    /// As _advance(duration), updating `other` beside the main oracle.
    function _advance(KyznUsdOracle other, uint256 duration) internal {
        while (duration != 0) {
            uint256 step = duration < SHORT ? duration : SHORT;
            vm.warp(block.timestamp + step);
            duration -= step;
            _update();
            if (address(other) != address(0)) other.update();
        }
        ethUsd.set(2_500e8, block.timestamp);
    }

    /// WETH per $KYZN (18 decimals) averaged from the newest observation this test saw at least
    /// `age` old up to now, from its own record of the cumulatives; ok is false when none is that
    /// old or it is more than `maxPeriod` old.
    function _expectedAverage(uint256 age, uint256 maxPeriod) internal view returns (uint256 kyznInEth, bool ok) {
        for (uint256 k = seenAt.length; k != 0; --k) {
            uint256 period = block.timestamp - seenAt[k - 1];
            if (period < age) continue;
            if (period > maxPeriod) return (0, false);
            uint256 average = (_expectedCumulative() - seenCumulative[k - 1]) / period;
            return (Math.mulDiv(average, 1e18, 2 ** 112), true);
        }
    }

    /// Both averages are available and equal the ones computed here, and price() is the lower
    /// times ETH/USD.
    function _assertLowerOfTheAverages() internal view {
        (uint256 shortEth, bool shortOk) = _expectedAverage(SHORT, 3 * SHORT);
        (uint256 longEth, bool longOk) = _expectedAverage(LONG, 2 * LONG);
        assertTrue(shortOk, "short average in range");
        assertTrue(longOk, "long average in range");
        (uint256 kyznInEth,) = oracle.shortTwap();
        assertEq(kyznInEth, shortEth, "short average");
        (kyznInEth,) = oracle.longTwap();
        assertEq(kyznInEth, longEth, "long average");
        assertEq(oracle.price(), Math.mulDiv(Math.min(shortEth, longEth), ETH_USD, 1e18), "the lower");
    }

    // ---------------------------------------------------------------- construction

    function test_constructor() public view {
        assertEq(address(oracle.pair()), address(pair));
        assertEq(oracle.kyzn(), address(kyzn));
        assertEq(oracle.weth(), address(weth));
        assertTrue(oracle.kyznIsToken0());
        assertEq(oracle.ethUsdFeed(), address(ethUsd));
        assertEq(oracle.ethUsdDecimals(), 8);
        assertEq(oracle.shortWindow(), SHORT);
        assertEq(oracle.longWindow(), LONG);
        assertEq(oracle.ringSize(), 52);
        assertEq(oracle.MAX_PERIOD_WINDOWS(), 3);
        assertEq(oracle.MAX_LONG_PERIOD_WINDOWS(), 2);
        assertEq(oracle.MAX_WINDOW_RATIO(), 96);
        assertEq(oracle.observationCount(), 1);
        (uint256 t, uint256 cumulative) = oracle.observation(0);
        assertEq(t, block.timestamp, "the first observation is recorded at deployment");
        assertEq(cumulative, seenCumulative[0]);
        assertFalse(oracle.due());
    }

    function test_constructor_rules() public {
        vm.expectRevert(KyznUsdOracle.ZeroAddress.selector);
        new KyznUsdOracle(IUniswapV2PairTwap(address(0)), address(kyzn), address(ethUsd), SHORT, LONG);
        vm.expectRevert(KyznUsdOracle.ZeroAddress.selector);
        new KyznUsdOracle(pair, address(0), address(ethUsd), SHORT, LONG);
        vm.expectRevert(KyznUsdOracle.ZeroAddress.selector);
        new KyznUsdOracle(pair, address(kyzn), address(0), SHORT, LONG);

        _expectBadWindows(0, LONG); // a short window
        _expectBadWindows(0, 0);
        _expectBadWindows(SHORT, 0);
        _expectBadWindows(SHORT, SHORT); // the long window at least two short windows
        _expectBadWindows(SHORT, 2 * SHORT - 1);
        _expectBadWindows(SHORT, LONG + 1); // a whole number of short windows
        _expectBadWindows(SHORT, LONG - 1);
        _expectBadWindows(7, 20);
        _expectBadWindows(SHORT, 97 * SHORT); // at most 96 short windows
        _expectBadWindows(1, 1_000);

        // The limits themselves, and testnet's 5 and 30 minutes.
        assertEq(new KyznUsdOracle(pair, address(kyzn), address(ethUsd), SHORT, 2 * SHORT).ringSize(), 8);
        assertEq(new KyznUsdOracle(pair, address(kyzn), address(ethUsd), SHORT, 96 * SHORT).ringSize(), 196);
        assertEq(new KyznUsdOracle(pair, address(kyzn), address(ethUsd), 5 minutes, 30 minutes).ringSize(), 16);

        address stranger = address(new MockToken("X", 18));
        vm.expectRevert(KyznUsdOracle.NotInPair.selector);
        new KyznUsdOracle(pair, stranger, address(ethUsd), SHORT, LONG);
        address wideFeed = address(new MockFeed(19, 1));
        vm.expectRevert(KyznUsdOracle.BadFeed.selector);
        new KyznUsdOracle(pair, address(kyzn), wideFeed, SHORT, LONG);

        MockToken six = new MockToken("SIX", 6);
        IUniswapV2PairTwap sixPair = IUniswapV2PairTwap(factory.createPair(address(six), address(weth)));
        vm.expectRevert(KyznUsdOracle.BadDecimals.selector);
        new KyznUsdOracle(sixPair, address(six), address(ethUsd), SHORT, LONG);
    }

    function _expectBadWindows(uint256 shortWindow, uint256 longWindow) internal {
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.BadWindows.selector, shortWindow, longWindow));
        new KyznUsdOracle(pair, address(kyzn), address(ethUsd), shortWindow, longWindow);
    }

    /// price() needs an observation one long window old: the short average is ready a short
    /// window after deployment, price() only a long window after it.
    function test_price_needs_one_long_window() public {
        uint256 deployedAt = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.TwapNotReady.selector, deployedAt + LONG));
        oracle.price();
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.TwapNotReady.selector, deployedAt + SHORT));
        oracle.shortTwap();
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.TwapNotReady.selector, deployedAt + LONG));
        oracle.longTwap();

        _advance(SHORT);
        (uint256 kyznInEth, uint256 period) = oracle.shortTwap();
        assertApproxEqRel(kyznInEth, 0.0001e18, PRECISION);
        assertEq(period, SHORT);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.TwapNotReady.selector, deployedAt + LONG));
        oracle.price();

        _advance(LONG - SHORT - 1);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.TwapNotReady.selector, deployedAt + LONG));
        oracle.price();

        vm.warp(block.timestamp + 1);
        ethUsd.set(2_500e8, block.timestamp);
        assertApproxEqRel(oracle.price(), KYZN_USD, PRECISION);
        (kyznInEth, period) = oracle.longTwap();
        assertApproxEqRel(kyznInEth, 0.0001e18, PRECISION);
        assertEq(period, LONG);
    }

    /// With a constant pool price the two averages are equal and price() is that price.
    function test_a_constant_pool_price_gives_equal_averages() public {
        _advance(LONG + 3 hours + 17 minutes);
        (uint256 shortEth, uint256 shortPeriod) = oracle.shortTwap();
        (uint256 longEth, uint256 longPeriod) = oracle.longTwap();
        assertEq(shortEth, longEth);
        assertEq(shortPeriod, SHORT + 17 minutes);
        assertEq(longPeriod, LONG + 17 minutes);
        assertEq(oracle.price(), Math.mulDiv(shortEth, ETH_USD, 1e18));
        assertApproxEqRel(oracle.price(), KYZN_USD, PRECISION);
        _assertLowerOfTheAverages();
    }

    /// The cumulative price is carried forward to now from the reserves, without any trade.
    function test_counterfactual_accumulation_matches_a_sync() public {
        _advance(LONG);
        _buyKyzn(pair, address(kyzn), 3e18);
        vm.warp(block.timestamp + 7);
        ethUsd.set(2_500e8, block.timestamp);
        uint256 before = oracle.price();
        (uint256 shortBefore,) = oracle.shortTwap();
        (uint256 longBefore,) = oracle.longTwap();
        pair.sync(); // writes the cumulative price up to now
        assertEq(oracle.price(), before);
        (uint256 kyznInEth,) = oracle.shortTwap();
        assertEq(kyznInEth, shortBefore);
        (kyznInEth,) = oracle.longTwap();
        assertEq(kyznInEth, longBefore);
    }

    function test_both_token_orders_give_the_same_price() public {
        (MockToken kyznHigh, ITestPair pairHigh) = _pool(KYZN_HIGH);
        KyznUsdOracle high = new KyznUsdOracle(pairHigh, address(kyznHigh), address(ethUsd), SHORT, LONG);
        assertFalse(high.kyznIsToken0());
        assertEq(high.weth(), address(weth));

        _advance(high, LONG / 2);
        _buyKyzn(pair, address(kyzn), 3e18);
        _buyKyzn(pairHigh, address(kyznHigh), 3e18);
        _advance(high, LONG / 2 + SHORT);
        (uint256 a,) = high.shortTwap();
        (uint256 b,) = oracle.shortTwap();
        assertEq(a, b);
        (a,) = high.longTwap();
        (b,) = oracle.longTwap();
        assertEq(a, b);
        assertEq(high.price(), oracle.price());
    }

    function test_eth_usd_decimals_are_scaled() public {
        MockFeed eth18 = new MockFeed(18, 2_500e18);
        KyznUsdOracle o18 = new KyznUsdOracle(pair, address(kyzn), address(eth18), SHORT, LONG);
        _advance(o18, LONG);
        eth18.set(2_500e18, block.timestamp);
        assertEq(o18.price(), oracle.price());
    }

    // ---------------------------------------------------------------- the averages

    /// Half a short window at one price, half at another: the short average is the average of the
    /// two; the long one carries the second price for half a short window of its 24 hours, and
    /// price() is the lower, the long one.
    function test_time_weighted_average() public {
        _advance(LONG);
        uint256 p1 = _spotUsd(pair, address(kyzn));
        vm.warp(block.timestamp + SHORT / 2);
        _buyKyzn(pair, address(kyzn), 10e18);
        uint256 p2 = _spotUsd(pair, address(kyzn));
        vm.warp(block.timestamp + SHORT / 2);
        ethUsd.set(2_500e8, block.timestamp);
        assertGt(p2, p1 * 12 / 10);
        (uint256 shortEth,) = oracle.shortTwap();
        assertApproxEqRel(shortEth * 2_500, (p1 + p2) / 2, PRECISION);
        (uint256 longEth,) = oracle.longTwap();
        uint256 longUsd = (p1 * (LONG - SHORT / 2) + p2 * (SHORT / 2)) / LONG;
        assertApproxEqRel(longEth * 2_500, longUsd, PRECISION);
        assertApproxEqRel(oracle.price(), longUsd, PRECISION);
    }

    /// Manipulation: a spike held for a whole short window. The short average becomes the spike;
    /// the long one carries it for one hour of 24, and price(), the lower, moves by that share only.
    function test_a_spike_held_one_short_window_moves_only_the_short_average() public {
        _advance(LONG); // a day of hourly observations; the newest is recorded now
        uint256 spot = _spotUsd(pair, address(kyzn));
        uint256 before = oracle.price();
        assertApproxEqRel(before, spot, PRECISION);

        _buyKyzn(pair, address(kyzn), 41e18); // the spot about doubles
        uint256 spiked = _spotUsd(pair, address(kyzn));
        assertGt(spiked, spot * 19 / 10);
        _advance(SHORT); // held for the whole short window; the worker records at its end

        (uint256 shortEth, uint256 shortPeriod) = oracle.shortTwap();
        (uint256 longEth, uint256 longPeriod) = oracle.longTwap();
        assertEq(shortPeriod, SHORT);
        assertEq(longPeriod, LONG);
        assertApproxEqRel(shortEth * 2_500, spiked, PRECISION, "the short average is the spike");
        uint256 longUsd = (spot * (LONG - SHORT) + spiked * SHORT) / LONG;
        assertApproxEqRel(longEth * 2_500, longUsd, PRECISION, "the long average carries 1 hour of 24");
        assertEq(oracle.price(), Math.mulDiv(longEth, ETH_USD, 1e18), "price() is the long average, the lower");
        assertApproxEqRel(oracle.price(), longUsd, PRECISION);
        assertLt(oracle.price(), before * 105 / 100, "a doubling held for an hour moves price() about 4%");
        _assertLowerOfTheAverages();
    }

    /// A sustained drop shows within a short window: price() follows the short average, the lower.
    function test_a_sustained_drop_lowers_the_price_through_the_short_average() public {
        _advance(LONG);
        uint256 spot = _spotUsd(pair, address(kyzn));
        _sellKyzn(pair, kyzn, 415_000e18); // the spot about halves
        uint256 dropped = _spotUsd(pair, address(kyzn));
        assertLt(dropped, spot * 51 / 100);
        _advance(SHORT);

        (uint256 shortEth,) = oracle.shortTwap();
        (uint256 longEth,) = oracle.longTwap();
        assertApproxEqRel(shortEth * 2_500, dropped, PRECISION, "the short average is the new price");
        assertApproxEqRel(longEth * 2_500, (spot * (LONG - SHORT) + dropped * SHORT) / LONG, PRECISION);
        assertEq(oracle.price(), Math.mulDiv(shortEth, ETH_USD, 1e18), "price() is the short average, the lower");
        assertApproxEqRel(oracle.price(), dropped, PRECISION);
        _assertLowerOfTheAverages();
    }

    /// TWAP manipulation: a swap that moves the spot price 100x in this block does not move
    /// price() at all, in this block, before or after update(). Uniswap v2 accumulates the price
    /// from before the block's first trade, and the oracle adds no time for reserves set this block.
    function test_single_block_spot_move_does_not_move_the_price() public {
        _advance(LONG);
        vm.warp(block.timestamp + SHORT + 5 minutes);
        ethUsd.set(2_500e8, block.timestamp);
        uint256 before = oracle.price();
        uint256 spotBefore = _spotUsd(pair, address(kyzn));

        _buyKyzn(pair, address(kyzn), 900e18); // the pool's WETH grows tenfold
        assertGt(_spotUsd(pair, address(kyzn)), spotBefore * 90, "spot moved about 100x");
        assertEq(oracle.price(), before, "same block: unchanged");

        assertTrue(oracle.update());
        assertEq(oracle.price(), before, "an observation in the same block is unaffected");

        _sellKyzn(pair, kyzn, 9_000_000e18); // and the attacker unwinds in the same block
        assertEq(oracle.price(), before);
    }

    /// A move held across blocks counts only for the seconds it stands: here 100x for 1 second
    /// of each average.
    function test_a_held_move_counts_by_its_seconds() public {
        _advance(LONG);
        vm.warp(block.timestamp + SHORT + 5 minutes - 1);
        ethUsd.set(2_500e8, block.timestamp);
        uint256 spot = _spotUsd(pair, address(kyzn));
        _buyKyzn(pair, address(kyzn), 900e18);
        uint256 pumped = _spotUsd(pair, address(kyzn));
        vm.warp(block.timestamp + 1);

        (uint256 shortEth, uint256 shortPeriod) = oracle.shortTwap();
        (uint256 longEth, uint256 longPeriod) = oracle.longTwap();
        assertEq(shortPeriod, SHORT + 5 minutes);
        assertEq(longPeriod, LONG + 5 minutes);
        assertApproxEqRel(shortEth * 2_500, (spot * (shortPeriod - 1) + pumped) / shortPeriod, PRECISION);
        assertApproxEqRel(longEth * 2_500, (spot * (longPeriod - 1) + pumped) / longPeriod, PRECISION);
        assertLt(shortEth * 2_500, spot * 103 / 100, "the short average: under 3%");
        assertEq(oracle.price(), Math.mulDiv(longEth, ETH_USD, 1e18), "price() is the long average, the lower");
        assertLt(oracle.price(), spot * 1_002 / 1_000, "price(): under 0.2% from a 100x spike held 1 second");
    }

    // ---------------------------------------------------------------- observations

    function test_update_records_at_most_once_per_short_window() public {
        uint256 deployedAt = block.timestamp;
        vm.warp(deployedAt + SHORT - 1);
        assertFalse(oracle.due());
        assertFalse(oracle.update());
        assertEq(oracle.observationCount(), 1);

        vm.warp(deployedAt + SHORT);
        assertTrue(oracle.due());
        uint256 cumulative = _expectedCumulative();
        vm.expectEmit(address(oracle));
        emit KyznUsdOracle.ObservationRecorded(block.timestamp, cumulative);
        vm.prank(makeAddr("anyone"));
        assertTrue(oracle.update());
        assertEq(oracle.observationCount(), 2);
        (uint256 newestAt, uint256 newestCumulative) = oracle.observation(0);
        (uint256 olderAt, uint256 olderCumulative) = oracle.observation(1);
        assertEq(newestAt, block.timestamp);
        assertEq(newestCumulative, cumulative);
        assertEq(olderAt, deployedAt);
        assertEq(olderCumulative, seenCumulative[0]);
        assertFalse(oracle.due());
        assertFalse(oracle.update());
        assertEq(oracle.observationCount(), 2);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.NoObservation.selector, 2));
        oracle.observation(2);

        // A late update records one observation, and the next is due a short window after it.
        vm.warp(block.timestamp + 2 * SHORT + 5);
        assertTrue(oracle.update());
        assertFalse(oracle.due());
        vm.warp(block.timestamp + SHORT - 1);
        assertFalse(oracle.due());
        vm.warp(block.timestamp + 1);
        assertTrue(oracle.due());
    }

    /// due() is true exactly when update() would record an observation.
    function testFuzz_due_is_exactly_when_update_records(uint256 first, uint256 second) public {
        first = bound(first, 0, 3 * SHORT);
        second = bound(second, 0, 3 * SHORT);
        vm.warp(block.timestamp + first);
        bool due = oracle.due();
        assertEq(oracle.update(), due);
        assertFalse(oracle.due());
        vm.warp(block.timestamp + second);
        due = oracle.due();
        assertEq(oracle.update(), due);
        assertFalse(oracle.due());
    }

    /// Just after an update the short average runs from the observation before; once the newest
    /// is a short window old, from it. The long one runs from the newest a long window old.
    function test_the_averages_run_from_the_newest_observation_old_enough() public {
        _advance(LONG); // observations every hour; the newest is recorded now
        uint256 newestAt = block.timestamp;
        vm.warp(newestAt + 10 minutes);
        (, uint256 period) = oracle.shortTwap();
        assertEq(period, SHORT + 10 minutes);
        (, period) = oracle.longTwap();
        assertEq(period, LONG + 10 minutes);
        vm.warp(newestAt + SHORT);
        (, period) = oracle.shortTwap();
        assertEq(period, SHORT);
        (, period) = oracle.longTwap();
        assertEq(period, LONG);
    }

    /// The ring keeps the newest observations, two long windows of short windows and four more,
    /// and never grows.
    function test_the_ring_keeps_the_newest_observations_and_never_grows() public {
        assertEq(oracle.ringSize(), SLOTS);
        for (uint256 i = 1; i <= 4 * LONG / SHORT; ++i) {
            _advance(SHORT);
            assertEq(oracle.observationCount(), Math.min(i + 1, SLOTS));
        }
        for (uint256 i; i < SLOTS; ++i) {
            (uint256 recordedAt, uint256 cumulative) = oracle.observation(i);
            assertEq(recordedAt, block.timestamp - i * SHORT);
            assertEq(cumulative, seenCumulative[seenAt.length - 1 - i]);
        }
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.NoObservation.selector, SLOTS));
        oracle.observation(SLOTS);
        _assertLowerOfTheAverages();
    }

    /// The widest ratio, 96 short windows to the long one (15 minutes and 24 hours): a ring of
    /// 196, wrapped, still finds both averages.
    function test_the_widest_ratio() public {
        KyznUsdOracle wide = new KyznUsdOracle(pair, address(kyzn), address(ethUsd), 15 minutes, 24 hours);
        assertEq(wide.ringSize(), 196);
        for (uint256 i; i < 2 * 196 + 7; ++i) {
            vm.warp(block.timestamp + 15 minutes);
            assertTrue(wide.update());
            assertLe(wide.observationCount(), 196);
        }
        ethUsd.set(2_500e8, block.timestamp);
        assertEq(wide.observationCount(), 196);
        (, uint256 period) = wide.shortTwap();
        assertEq(period, 15 minutes);
        (, period) = wide.longTwap();
        assertEq(period, 24 hours);
        assertApproxEqRel(wide.price(), KYZN_USD, PRECISION);
    }

    /// After a gap of more than three short windows the short average would be stale: price()
    /// reverts until an observation made after the gap is one short window old.
    function test_a_gap_stops_the_price_until_a_new_observation_is_a_short_window_old() public {
        _advance(LONG);
        uint256 lastAt = block.timestamp;
        vm.warp(lastAt + 3 * SHORT);
        ethUsd.set(2_500e8, block.timestamp);
        oracle.price(); // three short windows: still used

        vm.warp(lastAt + 3 * SHORT + 1);
        ethUsd.set(2_500e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 3 * SHORT));
        oracle.price();

        assertTrue(_update());
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 3 * SHORT));
        oracle.price();

        vm.warp(block.timestamp + SHORT - 1);
        ethUsd.set(2_500e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 3 * SHORT));
        oracle.price();

        vm.warp(block.timestamp + 1);
        ethUsd.set(2_500e8, block.timestamp);
        assertApproxEqRel(oracle.price(), KYZN_USD, PRECISION);
    }

    /// A gap shorter than a long window stops price() once: at once, until an observation after
    /// the gap is a short window old, and not again a long window later, when the long average
    /// reaches back across the gap (up to two long windows).
    function test_a_gap_under_a_day_stops_the_price_once() public {
        _advance(LONG);
        uint256 lastAt = block.timestamp;
        uint256 resumedAt = lastAt + 5 * SHORT; // five short windows with no observation
        vm.warp(resumedAt);
        ethUsd.set(2_500e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 3 * SHORT));
        oracle.price();
        assertTrue(_update());
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 3 * SHORT));
        oracle.price();

        _advance(SHORT); // one short window of fresh observations
        _assertLowerOfTheAverages();

        // Where the long average must start before the gap: from lastAt + LONG + 3 short windows
        // until the first observation after it is a long window old.
        _advance(LONG - 3 * SHORT);
        assertEq(block.timestamp, lastAt + LONG + 3 * SHORT);
        vm.warp(block.timestamp + 1);
        ethUsd.set(2_500e8, block.timestamp);
        (, uint256 period) = oracle.longTwap();
        assertEq(period, LONG + 3 * SHORT + 1, "the long average starts before the gap");
        _assertLowerOfTheAverages();
        _advance(2 * SHORT - 2);
        assertEq(block.timestamp, resumedAt + LONG - 1);
        (, period) = oracle.longTwap();
        assertEq(period, LONG + 5 * SHORT - 1, "the long average spans the whole gap");
        _assertLowerOfTheAverages();
        vm.warp(block.timestamp + 1);
        ethUsd.set(2_500e8, block.timestamp);
        (, period) = oracle.longTwap();
        assertEq(period, LONG);
        _assertLowerOfTheAverages();

        // And every hour for the next two days.
        for (uint256 i; i < 2 * LONG / SHORT; ++i) {
            _advance(SHORT);
            _assertLowerOfTheAverages();
        }
    }

    /// A gap longer than a long window still stops the long average: from two long windows after
    /// the last observation before the gap, until the first after it is a long window old. Here
    /// 30 hours: the price returns a short window after the gap, then stops for 6 hours from 18
    /// hours after it.
    function test_a_gap_over_a_day_stops_the_long_average_until_history_rebuilds() public {
        _advance(LONG);
        uint256 lastAt = block.timestamp;
        uint256 resumedAt = lastAt + 30 hours;
        vm.warp(resumedAt);
        assertTrue(_update());
        ethUsd.set(2_500e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 3 * SHORT));
        oracle.price();

        _advance(SHORT);
        (, uint256 period) = oracle.longTwap();
        assertEq(period, 31 hours, "the long average reaches back across the gap");
        _assertLowerOfTheAverages();

        _advance(lastAt + 2 * LONG - block.timestamp);
        (, period) = oracle.longTwap();
        assertEq(period, 2 * LONG);
        _assertLowerOfTheAverages();

        vm.warp(block.timestamp + 1);
        ethUsd.set(2_500e8, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 2 * LONG));
        oracle.price();
        (, period) = oracle.shortTwap();
        assertLe(period, 3 * SHORT, "the short average is fine");

        _advance(resumedAt + LONG - 1 - block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 2 * LONG));
        oracle.price();

        vm.warp(block.timestamp + 1);
        ethUsd.set(2_500e8, block.timestamp);
        (, period) = oracle.longTwap();
        assertEq(period, LONG);
        _assertLowerOfTheAverages();
    }

    /// A gap longer than two long windows stops price() until a long window of fresh observations.
    function test_a_gap_over_two_days_stops_the_price_for_a_long_window() public {
        _advance(LONG);
        uint256 lastAt = block.timestamp;
        uint256 resumedAt = lastAt + 3 days;
        vm.warp(resumedAt);
        assertTrue(_update());
        _advance(SHORT);
        (, uint256 period) = oracle.shortTwap();
        assertEq(period, SHORT, "the short average is back");
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 2 * LONG));
        oracle.price();

        _advance(LONG - SHORT - 1);
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.ObservationTooOld.selector, lastAt, 2 * LONG));
        oracle.price();

        vm.warp(block.timestamp + 1);
        ethUsd.set(2_500e8, block.timestamp);
        assertApproxEqRel(oracle.price(), KYZN_USD, PRECISION);
        _assertLowerOfTheAverages();
    }

    /// update() at least once per short window keeps price() available while the pool trades:
    /// the short average over one to three short windows, the long one over a long window and at
    /// most three short windows more, and price() the lower of the two.
    function test_regular_updates_keep_the_price_available() public {
        for (uint256 i; i < 200; ++i) {
            vm.warp(block.timestamp + 1 + (i * 7919) % SHORT);
            _update();
            if (i % 3 == 0) _buyKyzn(pair, address(kyzn), 1e17);
            else _sellKyzn(pair, kyzn, 500e18);
            if (block.timestamp < START + LONG) continue;
            ethUsd.set(2_500e8, block.timestamp);
            (, uint256 period) = oracle.shortTwap();
            assertGe(period, SHORT);
            assertLe(period, 3 * SHORT);
            (, period) = oracle.longTwap();
            assertGe(period, LONG);
            assertLe(period, LONG + 3 * SHORT);
            _assertLowerOfTheAverages();
        }
        assertEq(oracle.observationCount(), SLOTS);
    }

    /// Several days of updates one to two short windows apart, at a fuzzed cadence, while the
    /// pool trades: the ring wraps, price() stays available, and it equals the lower of the two
    /// averages computed here from the cumulatives recorded at each update().
    function testFuzz_the_ring_wraps_and_price_is_the_lower_average(uint256 seed) public {
        uint256 end = block.timestamp + 5 days;
        while (block.timestamp < end) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 step = SHORT + seed % (SHORT + 1); // one to two short windows
            uint256 tradeAt = (seed >> 64) % step;
            vm.warp(block.timestamp + tradeAt);
            if ((seed >> 128) % 2 == 0) _buyKyzn(pair, address(kyzn), 1e18 + (seed >> 136) % 5e18);
            else _sellKyzn(pair, kyzn, 10_000e18 + (seed >> 136) % 50_000e18);
            vm.warp(block.timestamp + step - tradeAt);
            ethUsd.set(2_500e8, block.timestamp);
            if (block.timestamp >= START + LONG) _assertLowerOfTheAverages();
            assertTrue(oracle.due());
            assertTrue(_update());
            assertLe(oracle.observationCount(), SLOTS);
            if (block.timestamp >= START + LONG) _assertLowerOfTheAverages();
        }
        assertEq(oracle.observationCount(), SLOTS);
        for (uint256 i; i < SLOTS; ++i) {
            (uint256 recordedAt, uint256 cumulative) = oracle.observation(i);
            assertEq(recordedAt, seenAt[seenAt.length - 1 - i]);
            assertEq(cumulative, seenCumulative[seenCumulative.length - 1 - i]);
        }
    }

    // ---------------------------------------------------------------- ETH/USD and edges

    /// The Reserve's staleness rule: the ETH/USD answer at most 24 hours old, and positive.
    function test_eth_usd_must_be_fresh_and_positive() public {
        _advance(LONG);
        ethUsd.set(2_500e8, block.timestamp - 24 hours);
        oracle.price();
        ethUsd.set(2_500e8, block.timestamp - 24 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(PriceLib.StalePrice.selector, address(ethUsd)));
        oracle.price();
        ethUsd.set(0, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PriceLib.BadPrice.selector, address(ethUsd)));
        oracle.price();
    }

    function test_price_scales_with_eth_usd() public {
        _advance(LONG);
        uint256 at2500 = oracle.price();
        ethUsd.set(5_000e8, block.timestamp);
        assertEq(oracle.price(), at2500 * 2);
    }

    function test_an_average_that_rounds_to_zero_reverts() public {
        deployCodeTo("SiliconMocks.sol:MockToken", abi.encode("DUST", uint8(18)), address(0x2000));
        MockToken dust = MockToken(address(0x2000));
        ITestPair p = ITestPair(factory.createPair(address(dust), address(weth)));
        dust.mint(address(p), 1e30);
        vm.deal(address(this), 1_000);
        weth.deposit{value: 1_000}();
        assertTrue(weth.transfer(address(p), 1_000));
        p.mint(address(this));
        KyznUsdOracle o = new KyznUsdOracle(p, address(dust), address(ethUsd), SHORT, LONG);
        _advance(o, LONG);
        vm.expectRevert(KyznUsdOracle.ZeroPrice.selector);
        o.price();
        vm.expectRevert(KyznUsdOracle.ZeroPrice.selector);
        o.shortTwap();
    }

    /// Uniswap v2 keeps time modulo 2**32 (it wraps in February 2106); the oracle follows it.
    function test_uint32_time_wrap() public {
        vm.warp(2 ** 32 - LONG);
        pair.sync();
        KyznUsdOracle o = new KyznUsdOracle(pair, address(kyzn), address(ethUsd), SHORT, LONG);
        _advance(o, LONG + 20 minutes);
        _buyKyzn(pair, address(kyzn), 1e18); // the pair's timestamp wraps here
        _advance(o, 5 minutes);
        assertEq(block.timestamp, 2 ** 32 + 25 minutes);
        uint256 p = o.price();
        assertApproxEqRel(p, KYZN_USD, 0.02e18);
        assertGt(p, KYZN_USD);
        (, uint256 period) = o.longTwap();
        assertEq(period, LONG + 25 minutes, "the long average spans the wrap");
    }

    receive() external payable {}
}
