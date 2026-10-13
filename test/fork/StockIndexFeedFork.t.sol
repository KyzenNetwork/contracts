// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {MarketCalendar} from "../../src/silicon/MarketCalendar.sol";
import {StockIndexFeed} from "../../src/silicon/StockIndexFeed.sol";
import {IMarketCalendar} from "../../src/silicon/interfaces/IMarketCalendar.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";

/// What a Chainlink feed says about itself, which IAggregatorV3 leaves out.
interface IFeedDescription {
    function description() external view returns (string memory);
}

/// The four stock indices (Design, Memory, Fab, Equipment) on the seven real Chainlink feeds of
/// Robinhood Chain mainnet, read only: the feeds, the calendar and the indices are deployed on the
/// fork and nothing is sent to the chain. Skipped unless ROBINHOOD_RPC_URL names a Robinhood Chain
/// mainnet RPC. The public RPC blocks the burst of requests a fork makes, so point the variable at
/// a local forwarder that sends them one at a time. The fork is made once, in setUp, at the latest
/// block (the public RPC keeps about twenty minutes of state, so a pinned block would go stale).
contract StockIndexFeedForkTest is Test {
    uint256 internal constant FEEDS = 7;
    uint256 internal constant INDICES = 4;
    /// Rounds read back from each feed, below the latest.
    uint80 internal constant HISTORY = 20;

    MarketCalendar internal cal;
    StockIndexFeed[INDICES] internal indices;

    function setUp() public {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true, "ROBINHOOD_RPC_URL is not set");
        vm.createSelectFork(url);
        assertEq(block.chainid, RH.CHAIN_ID, "the fork is not Robinhood Chain mainnet");

        cal = new MarketCalendar(address(this));
        for (uint256 s; s < INDICES; ++s) {
            address[] memory components = new address[](_indexSize(s));
            for (uint256 j; j < components.length; ++j) {
                components[j] = _feed(_indexStart(s) + j);
            }
            indices[s] = new StockIndexFeed(_indexName(s), IMarketCalendar(address(cal)), components, address(this));
        }
    }

    // ---------------------------------------------------------------- the feeds

    /// Every component feed answers in 8 decimals, and the index read the same.
    function test_every_component_reports_8_decimals() public view {
        for (uint256 i; i < FEEDS; ++i) {
            assertEq(IAggregatorV3(_feed(i)).decimals(), 8, _ticker(i));
        }
        for (uint256 s; s < INDICES; ++s) {
            assertEq(indices[s].componentCount(), _indexSize(s), _indexName(s));
            for (uint256 j; j < indices[s].componentCount(); ++j) {
                (address feed, uint8 decimals, uint256 quantity) = indices[s].component(j);
                assertEq(feed, _feed(_indexStart(s) + j), "the component is the stock's feed");
                assertEq(decimals, 8, _ticker(_indexStart(s) + j));
                assertGt(quantity, 0, "a component holds some of the stock");
            }
        }
    }

    /// Each feed's description names its stock.
    function test_every_feed_names_its_ticker() public view {
        for (uint256 i; i < FEEDS; ++i) {
            string memory description = IFeedDescription(_feed(i)).description();
            console2.log(description);
            assertTrue(vm.contains(description, _ticker(i)), string.concat(_ticker(i), " is not in: ", description));
        }
    }

    // ---------------------------------------------------------------- the indices

    /// Each index starts at 100 USD: the quantities round down and each component's value rounds
    /// up, so the price is a hair either side, and its update time is the oldest component's.
    function test_each_index_starts_at_100_usd() public view {
        for (uint256 s; s < INDICES; ++s) {
            (uint256 price, uint256 updatedAt) = indices[s].latestPrice();
            console2.log(_indexName(s), price);
            assertGe(price, 99.999999e18, _indexName(s));
            assertLe(price, 100.000001e18, _indexName(s));
            (uint256 oldest,) = _updates(s);
            assertEq(updatedAt, oldest, "the index is as old as its oldest component");
            for (uint256 j; j < indices[s].componentCount(); ++j) {
                assertFalse(indices[s].jumped(j), "no component starts stopped");
                (uint80 latest,,,,) = IAggregatorV3(_feed(_indexStart(s) + j)).latestRoundData();
                assertEq(indices[s].checkedRound(j), latest, "the checked round is the deployment round");
            }
        }
    }

    /// isFreshForLiquidation() is every component updated within 96 hours, as the feeds' own
    /// update times say; isFresh() is also the calendar's window and within 24 hours. At the
    /// edges: exactly 96 hours old is fresh for liquidation, one second more is not.
    function test_freshness_follows_the_feeds_update_times() public {
        uint256 now_ = block.timestamp;
        for (uint256 s; s < INDICES; ++s) {
            (uint256 oldest,) = _updates(s);
            assertLe(oldest, now_, "no update is from the future");
            console2.log(_indexName(s), "oldest update, seconds ago", now_ - oldest);
            assertEq(indices[s].isFreshForLiquidation(), now_ - oldest <= 96 hours, "liquidation freshness");
            assertEq(indices[s].isFresh(), cal.isMintWindow(now_) && now_ - oldest <= 24 hours, "mint freshness");

            // The edges, when the oldest update is within 96 hours (otherwise it is stale as it is).
            if (oldest + 96 hours >= now_) {
                vm.warp(oldest + 96 hours);
                assertTrue(indices[s].isFreshForLiquidation(), "96 hours old is still fresh");
                vm.warp(oldest + 96 hours + 1);
                assertFalse(indices[s].isFreshForLiquidation(), "96 hours and a second is stale");
            }

            // The next moment inside the window: fresh for a mint exactly when under 24 hours old.
            uint256 inWindow = _windowAtOrAfter(now_);
            vm.warp(inWindow);
            assertEq(indices[s].isFresh(), inWindow - oldest <= 24 hours, "mint freshness inside the window");
            // The first window moment past 24 hours: stale for a mint, still maybe fresh to liquidate.
            inWindow = _windowAtOrAfter(Math.max(oldest + 24 hours + 1, now_));
            vm.warp(inWindow);
            assertFalse(indices[s].isFresh(), "over 24 hours old is stale for a mint, window or not");
            // The edge itself, when it falls inside the window.
            if (oldest + 24 hours >= now_ && cal.isMintWindow(oldest + 24 hours) && cal.isMintWindow(oldest + 24 hours + 1))
            {
                vm.warp(oldest + 24 hours);
                assertTrue(indices[s].isFresh(), "24 hours old is still fresh for a mint");
                vm.warp(oldest + 24 hours + 1);
                assertFalse(indices[s].isFresh(), "24 hours and a second is stale for a mint");
            }
            vm.warp(now_);
        }
    }

    /// The last HISTORY rounds below the latest of every feed answer through the same gas-capped
    /// read the index uses (getRoundData for the jump check), with positive answers and update
    /// times that never go back. Round ids carry the aggregator's phase in the top 16 bits; today
    /// every feed is on phase 1, and a phase change would need a different walk, so the walk below
    /// stays inside the latest round's phase.
    function test_recent_rounds_read_cleanly() public view {
        for (uint256 i; i < FEEDS; ++i) {
            address feed = _feed(i);
            (uint80 latest, int256 latestAnswer,, uint256 latestUpdatedAt,) = IAggregatorV3(feed).latestRoundData();
            assertGt(latestAnswer, 0, _ticker(i));
            // The low 64 bits are the aggregator's own round, the top 16 its phase.
            // forge-lint: disable-next-line(unsafe-typecast)
            uint64 round = uint64(latest);
            assertGt(round, HISTORY, "the phase has more rounds than the walk reads");
            console2.log(_ticker(i), "phase / round", latest >> 64, round);

            uint256 previousTime;
            uint256 largestStepBps;
            int256 previousAnswer;
            for (uint80 k = HISTORY; k > 0; --k) {
                uint80 want = latest - k;
                (bool ok, bytes memory ret) =
                    feed.staticcall{gas: PriceLib.FEED_GAS}(abi.encodeCall(IAggregatorV3.getRoundData, (want)));
                assertTrue(ok, string.concat(_ticker(i), " getRoundData reverted or ran out of gas"));
                assertGe(ret.length, 160, "five words");
                (uint80 id, int256 answer,, uint256 updatedAt,) =
                    abi.decode(ret, (uint80, int256, uint256, uint256, uint80));
                assertEq(id, want, "the round asked for");
                assertGt(answer, 0, "a positive answer");
                assertGe(updatedAt, previousTime, "update times do not go back");
                if (previousAnswer != 0) {
                    uint256 step = _stepBps(previousAnswer, answer);
                    if (step > largestStepBps) largestStepBps = step;
                }
                previousTime = updatedAt;
                previousAnswer = answer;
            }
            assertGe(latestUpdatedAt, previousTime, "the latest round is not older than the one before");
            uint256 lastStep = _stepBps(previousAnswer, latestAnswer);
            if (lastStep > largestStepBps) largestStepBps = lastStep;
            // Information, not a rule: the breaker stops at 3,000 basis points between two rounds.
            console2.log(_ticker(i), "largest step between rounds, basis points", largestStepBps);
        }
    }

    // ---------------------------------------------------------------- the basket

    /// Design: NVDA, AMD. Memory: MU, SNDK. Fab: TSM, INTC. Equipment: ASML.
    function _indexStart(uint256 s) internal pure returns (uint256) {
        return s * 2;
    }

    function _indexSize(uint256 s) internal pure returns (uint256) {
        return s == 3 ? 1 : 2;
    }

    function _indexName(uint256 s) internal pure returns (string memory) {
        if (s == 0) return "kDESIGN / USD";
        if (s == 1) return "kMEMORY / USD";
        if (s == 2) return "kFAB / USD";
        return "kEQUIP / USD";
    }

    /// The seven feeds in the order NVDA, AMD, MU, SNDK, TSM, INTC, ASML.
    function _feed(uint256 i) internal pure returns (address) {
        if (i == 0) return RH.NVDA_USD;
        if (i == 1) return RH.AMD_USD;
        if (i == 2) return RH.MU_USD;
        if (i == 3) return RH.SNDK_USD;
        if (i == 4) return RH.TSM_USD;
        if (i == 5) return RH.INTC_USD;
        return RH.ASML_USD;
    }

    function _ticker(uint256 i) internal pure returns (string memory) {
        if (i == 0) return "NVDA";
        if (i == 1) return "AMD";
        if (i == 2) return "MU";
        if (i == 3) return "SNDK";
        if (i == 4) return "TSM";
        if (i == 5) return "INTC";
        return "ASML";
    }

    /// The oldest and the newest update time among index `s`'s components, from the feeds
    /// themselves.
    function _updates(uint256 s) internal view returns (uint256 oldest, uint256 newest) {
        oldest = type(uint256).max;
        for (uint256 j; j < _indexSize(s); ++j) {
            (,,, uint256 updatedAt,) = IAggregatorV3(_feed(_indexStart(s) + j)).latestRoundData();
            if (updatedAt < oldest) oldest = updatedAt;
            if (updatedAt > newest) newest = updatedAt;
        }
    }

    /// The first moment at or after `from` that the calendar calls a mint window.
    function _windowAtOrAfter(uint256 from) internal view returns (uint256) {
        if (cal.isMintWindow(from)) return from;
        for (uint256 day = from / 1 days; day <= from / 1 days + 10; ++day) {
            uint256 t = day * 1 days + 14 hours + 30 minutes;
            if (t >= from && cal.isMintWindow(t)) return t;
        }
        revert("no mint window in ten days");
    }

    /// The move from `previous` to `current`, in basis points of `previous` (both positive).
    function _stepBps(int256 previous, int256 current) internal pure returns (uint256) {
        uint256 p = SafeCast.toUint256(previous);
        uint256 c = SafeCast.toUint256(current);
        return (c > p ? c - p : p - c) * 10_000 / p;
    }
}
