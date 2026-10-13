// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {stdError} from "forge-std/StdError.sol";
import {KyznUsdOracle} from "../../src/silicon/KyznUsdOracle.sol";
import {IUniswapV2PairTwap} from "../../src/silicon/interfaces/IUniswapV2PairTwap.sol";
import {IUniswapV2Factory} from "../../src/interfaces/IUniswapV2.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {MockFeed} from "../mocks/MockFeed.sol";
import {MockToken} from "./mocks/SiliconMocks.sol";
import {KyznUsdOracleHarness} from "./utils/KyznUsdOracleHarness.sol";

/// The pair's mint, which seeds the pool here, beside what the oracle reads.
interface IMintPair is IUniswapV2PairTwap {
    function mint(address to) external returns (uint256 liquidity);
}

/// KyznUsdOracle's observation search, a binary search over the held observations: it finds
/// exactly what the linear walk it replaced found, on histories update() makes and on any ring
/// with strictly decreasing timestamps; and the gas of price() with every slot cold.
contract KyznUsdOracleSearchTest is Test {
    uint256 internal constant START = 1_790_604_000;

    MockWETH internal weth;
    MockFeed internal ethUsd;
    MockToken internal kyzn;
    IMintPair internal pair;

    function setUp() public {
        vm.warp(START);
        weth = new MockWETH();
        IUniswapV2Factory factory =
            IUniswapV2Factory(deployCode("external/uniswap-v2/UniswapV2Factory.json", abi.encode(address(this))));
        ethUsd = new MockFeed(8, 2_500e8);
        deployCodeTo("SiliconMocks.sol:MockToken", abi.encode("KYZN", uint8(18)), address(0x1000));
        kyzn = MockToken(address(0x1000));
        pair = IMintPair(factory.createPair(address(kyzn), address(weth)));
        kyzn.mint(address(pair), 1_000_000e18);
        vm.deal(address(this), 100e18);
        weth.deposit{value: 100e18}();
        assertTrue(weth.transfer(address(pair), 100e18));
        pair.mint(address(this));
    }

    // ---------------------------------------------------------------- the same as the linear walk

    function _harness(uint256 shortWindow, uint256 longWindow) internal returns (KyznUsdOracleHarness) {
        return new KyznUsdOracleHarness(pair, address(kyzn), address(ethUsd), shortWindow, longWindow);
    }

    /// The binary search and the linear walk return the same observation, or revert with the same
    /// data.
    function _assertSame(KyznUsdOracleHarness h, uint256 age) internal view {
        (bool searched, bytes memory found) = address(h).staticcall(abi.encodeCall(h.findAtLeast, (age)));
        (bool walked, bytes memory expected) = address(h).staticcall(abi.encodeCall(h.findAtLeastLinear, (age)));
        assertEq(searched, walked, "both return, or both revert");
        assertEq(found, expected, "the same observation, or the same revert data");
    }

    /// The same at the oracle's two ages, at a random one, and at a random held observation's age
    /// and one second either side of it.
    function _assertSameAround(KyznUsdOracleHarness h, uint256 r) internal view {
        _assertSame(h, h.shortWindow());
        _assertSame(h, h.longWindow());
        _assertSame(h, r % (3 * h.longWindow()));
        (uint256 t,) = h.observation((r >> 128) % h.observationCount());
        uint256 age = block.timestamp - t;
        _assertSame(h, age);
        _assertSame(h, age + 1);
        if (age != 0) _assertSame(h, age - 1);
    }

    /// Histories as update() records them, compared after every step: observations one to three
    /// short windows apart (often exactly one, or within the worker's minute of it), now and then
    /// a gap of up to three days, update() again in the same block and before one is due, until
    /// the ring has wrapped twice.
    function _fuzzHistory(uint256 seed, uint256 shortWindow, uint256 longWindow) internal {
        KyznUsdOracleHarness h = _harness(shortWindow, longWindow);
        _assertSameAround(h, seed);
        uint256 records = 1;
        while (records < 2 * h.ringSize() + 7) {
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 kind = seed % 64;
            uint256 r = seed >> 8;
            uint256 step;
            if (kind == 0) step = 3 * shortWindow + r % 3 days; // a gap
            else if (kind < 4) step = 0; // again in the same block
            else if (kind < 12) step = r % shortWindow; // before the next is due
            else if (kind < 28) step = shortWindow; // exactly when due
            else if (kind < 40) step = shortWindow + r % 61; // within the worker's minute
            else step = shortWindow + r % (2 * shortWindow + 1); // one to three short windows
            vm.warp(block.timestamp + step);
            bool due = h.due();
            assertEq(h.update(), due);
            if (due) ++records;
            if ((seed >> 7) % 4 == 0) assertFalse(h.update(), "a second update() in the block records nothing");
            _assertSameAround(h, seed >> 16);
        }
        assertEq(h.observationCount(), h.ringSize());
        // Every held observation's age, and one second either side, after the last step.
        for (uint256 k; k < h.ringSize(); ++k) {
            (uint256 t,) = h.observation(k);
            uint256 age = block.timestamp - t;
            _assertSame(h, age);
            _assertSame(h, age + 1);
            if (age != 0) _assertSame(h, age - 1);
        }
    }

    /// Mainnet's windows, 1 hour and 24 hours: a ring of 52.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_matches_the_linear_walk_on_histories_ratio_24(uint256 seed) public {
        _fuzzHistory(seed, 1 hours, 24 hours);
    }

    /// The widest ratio, 15 minutes and 24 hours: a ring of 196.
    /// forge-config: default.fuzz.runs = 64
    function testFuzz_matches_the_linear_walk_on_histories_ratio_96(uint256 seed) public {
        _fuzzHistory(seed, 15 minutes, 24 hours);
    }

    /// Testnet's windows, 5 minutes and 30 minutes: a ring of 16.
    function testFuzz_matches_the_linear_walk_on_histories_testnet(uint256 seed) public {
        _fuzzHistory(seed, 5 minutes, 30 minutes);
    }

    /// Any ring whose timestamps strictly decrease from the newest back, spaced 1 second to 5 days
    /// apart (closer than a short window too, which update() never records), with any number
    /// recorded, read at any time from before the newest observation on, at any age: the same
    /// observation, or the same revert data (Panic when the clock reads before the newest, as no
    /// chain does).
    function testFuzz_matches_the_linear_walk_on_any_ring(
        uint256 seed,
        uint8 windows,
        uint256 recorded,
        uint256 sinceNewest,
        uint256 age
    ) public {
        windows %= 3;
        KyznUsdOracleHarness h = windows == 0
            ? _harness(1 hours, 24 hours)
            : windows == 1 ? _harness(15 minutes, 24 hours) : _harness(5 minutes, 30 minutes);
        uint256 shortWindow = h.shortWindow();
        recorded = bound(recorded, 1, 3 * h.ringSize());
        uint256 count = Math.min(recorded, h.ringSize());
        uint256[] memory timestamps = new uint256[](count);
        uint256 t = 1e12;
        for (uint256 k; k < count; ++k) {
            timestamps[k] = t;
            seed = uint256(keccak256(abi.encode(seed)));
            uint256 kind = seed % 8;
            uint256 r = seed >> 8;
            if (kind == 0) t -= 1 + r % 60;
            else if (kind == 1) t -= 1 + r % 5 days;
            else if (kind == 2) t -= shortWindow;
            else t -= shortWindow + r % (2 * shortWindow + 1);
        }
        h.setHistory(recorded, timestamps);
        if (sinceNewest % 8 == 0) vm.warp(timestamps[0] - 1 - (sinceNewest >> 8) % 1_000);
        else vm.warp(timestamps[0] + (sinceNewest >> 8) % (3 * h.longWindow() + 3 days));

        _assertSame(h, age);
        _assertSame(h, age % (3 * h.longWindow()));
        _assertSame(h, 0);
        _assertSame(h, type(uint256).max);
        _assertSame(h, shortWindow);
        _assertSame(h, h.longWindow());
        for (uint256 k; k < count; ++k) {
            if (timestamps[k] > block.timestamp) continue;
            uint256 a = block.timestamp - timestamps[k];
            _assertSame(h, a);
            _assertSame(h, a + 1);
            if (a != 0) _assertSame(h, a - 1);
        }
    }

    /// Before any observation is old enough, both revert TwapNotReady at the oldest's timestamp
    /// plus the age; with the clock before the newest, both Panic.
    function test_matches_the_linear_walk_at_the_edges() public {
        KyznUsdOracleHarness h = _harness(1 hours, 24 hours);
        uint256 deployedAt = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.TwapNotReady.selector, deployedAt + 24 hours));
        h.findAtLeast(24 hours);
        _assertSame(h, 24 hours);
        _assertSame(h, 1 hours);
        (uint256 t, uint256 cumulative) = h.findAtLeast(0);
        assertEq(t, deployedAt);
        (uint256 tLinear, uint256 cumulativeLinear) = h.findAtLeastLinear(0);
        assertEq(tLinear, t);
        assertEq(cumulativeLinear, cumulative);

        for (uint256 i; i < 30; ++i) {
            vm.warp(block.timestamp + 1 hours);
            assertTrue(h.update());
        }
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.TwapNotReady.selector, deployedAt + 31 hours));
        h.findAtLeast(31 hours);
        _assertSame(h, 31 hours);
        (t,) = h.findAtLeast(30 hours);
        assertEq(t, deployedAt);
        (t,) = h.findAtLeast(24 hours);
        assertEq(t, deployedAt + 6 hours);

        vm.warp(block.timestamp - 1);
        vm.expectRevert(stdError.arithmeticError);
        h.findAtLeast(0);
        _assertSame(h, 0);
        _assertSame(h, 24 hours);
    }

    // ---------------------------------------------------------------- gas

    /// An oracle with `shortWindow` / `longWindow`, updated every `cadence` until its ring is full
    /// and wrapped, then read `phase` seconds after its newest observation.
    function _oracleAfterHistory(uint256 shortWindow, uint256 longWindow, uint256 cadence, uint256 phase)
        internal
        returns (KyznUsdOracle o)
    {
        o = new KyznUsdOracle(pair, address(kyzn), address(ethUsd), shortWindow, longWindow);
        for (uint256 i = o.ringSize() + 7; i != 0; --i) {
            vm.warp(block.timestamp + cadence);
            assertTrue(o.update());
        }
        assertEq(o.observationCount(), o.ringSize(), "the ring is full");
        vm.warp(block.timestamp + phase);
        ethUsd.set(2_500e8, block.timestamp);
    }

    /// The gas of price() with the oracle, the pair and the feed all cold, as the first read of a
    /// transaction.
    function _coldPriceGas(KyznUsdOracle o) internal returns (uint256 gasUsed) {
        vm.cool(address(o));
        vm.cool(address(pair));
        vm.cool(address(ethUsd));
        uint256 before = gasleft();
        o.price();
        gasUsed = before - gasleft();
    }

    /// _coldPriceGas after the history above, logged; the state is restored after.
    function _logColdPriceGas(
        string memory label,
        uint256 shortWindow,
        uint256 longWindow,
        uint256 cadence,
        uint256 phase
    ) internal returns (uint256 gasUsed) {
        uint256 snapshot = vm.snapshotState();
        gasUsed = _coldPriceGas(_oracleAfterHistory(shortWindow, longWindow, cadence, phase));
        emit log_named_uint(label, gasUsed);
        vm.revertToState(snapshot);
    }

    /// price() read its observations by walking back from the newest, one cold timestamp each:
    /// 88,225 gas here at 1 hour / 24 hours and 271,969 at 15 minutes / 24 hours (the walk at
    /// commit 857d63a). With observations one short window apart the search reads seven of the
    /// oracle's slots, at every ratio; further apart, a binary search's share more.
    function test_gas_price_cold() public {
        uint256 regular = 40_000;
        assertLe(
            _logColdPriceGas("1 h / 24 h, hourly, read 20 min after", 1 hours, 24 hours, 1 hours, 20 minutes), regular
        );
        assertLe(_logColdPriceGas("1 h / 24 h, hourly, read at the update", 1 hours, 24 hours, 1 hours, 0), regular);
        assertLe(
            _logColdPriceGas("1 h / 24 h, hourly, read 1 s before due", 1 hours, 24 hours, 1 hours, 1 hours - 1),
            regular
        );
        assertLe(
            _logColdPriceGas(
                "15 min / 24 h, every 15 min, read 5 min after", 15 minutes, 24 hours, 15 minutes, 5 minutes
            ),
            regular
        );
        assertLe(
            _logColdPriceGas("15 min / 24 h, every 15 min, read at the update", 15 minutes, 24 hours, 15 minutes, 0),
            regular
        );
        assertLe(
            _logColdPriceGas(
                "5 min / 30 min, every 5 min, read 2 min after", 5 minutes, 30 minutes, 5 minutes, 2 minutes
            ),
            regular
        );

        uint256 drifting = 60_000;
        assertLe(
            _logColdPriceGas("1 h / 24 h, every 61 min, read 20 min after", 1 hours, 24 hours, 61 minutes, 20 minutes),
            drifting
        );
        assertLe(
            _logColdPriceGas("1 h / 24 h, every 62 min, read 20 min after", 1 hours, 24 hours, 62 minutes, 20 minutes),
            drifting
        );
        assertLe(
            _logColdPriceGas("1 h / 24 h, every 2 h, read 20 min after", 1 hours, 24 hours, 2 hours, 20 minutes),
            drifting
        );
        assertLe(
            _logColdPriceGas(
                "15 min / 24 h, every 16 min, read 5 min after", 15 minutes, 24 hours, 16 minutes, 5 minutes
            ),
            drifting
        );
        assertLe(
            _logColdPriceGas(
                "15 min / 24 h, every 30 min, read 5 min after", 15 minutes, 24 hours, 30 minutes, 5 minutes
            ),
            drifting
        );
        assertLe(
            _logColdPriceGas(
                "5 min / 30 min, every 6 min, read 2 min after", 5 minutes, 30 minutes, 6 minutes, 2 minutes
            ),
            drifting
        );
    }

    receive() external payable {}
}
