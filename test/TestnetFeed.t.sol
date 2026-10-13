// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {TestnetFeed} from "../script/testnet/TestnetFeed.sol";
import {MarketCalendar} from "../src/silicon/MarketCalendar.sol";
import {StockIndexFeed} from "../src/silicon/StockIndexFeed.sol";
import {IMarketCalendar} from "../src/silicon/interfaces/IMarketCalendar.sol";

/// The testnet stand-in for a Chainlink feed keeps every round, so a StockIndexFeed can walk
/// them with getRoundData as it does on mainnet.
contract TestnetFeedTest is Test {
    uint256 internal constant START = 1_790_604_000; // Monday 28 September 2026, 14:00 UTC
    int256 internal constant PRICE = 200e8;

    TestnetFeed internal feed;
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(START);
        feed = new TestnetFeed("NVDA / USD testnet stand-in", PRICE);
    }

    function _round(uint80 id)
        internal
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        return feed.getRoundData(id);
    }

    function test_constructor_records_round_one() public view {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = _round(1);
        assertEq(roundId, 1);
        assertEq(answer, PRICE);
        assertEq(startedAt, START);
        assertEq(updatedAt, START);
        assertEq(answeredInRound, 1);
    }

    function test_set_records_each_round_and_keeps_the_earlier_ones() public {
        feed.set(210e8, START + 60);
        feed.set(190e8, START + 120);

        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) = _round(1);
        assertEq(roundId, 1);
        assertEq(answer, PRICE);
        assertEq(startedAt, START);
        assertEq(updatedAt, START);
        assertEq(answeredInRound, 1);

        (roundId, answer, startedAt, updatedAt, answeredInRound) = _round(2);
        assertEq(roundId, 2);
        assertEq(answer, 210e8);
        assertEq(startedAt, START + 60);
        assertEq(updatedAt, START + 60);
        assertEq(answeredInRound, 2);

        (roundId, answer, startedAt, updatedAt, answeredInRound) = _round(3);
        assertEq(roundId, 3);
        assertEq(answer, 190e8);
        assertEq(updatedAt, START + 120);
        assertEq(answeredInRound, 3);
    }

    function test_latest_round_data_matches_the_newest_round() public {
        feed.set(210e8, START + 60);
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            feed.latestRoundData();
        assertEq(roundId, 2);
        assertEq(answer, 210e8);
        assertEq(startedAt, START + 60);
        assertEq(updatedAt, START + 60);
        assertEq(answeredInRound, 2);
        assertEq(feed.roundId(), 2);
        assertEq(feed.answer(), 210e8);
        assertEq(feed.updatedAt(), START + 60);
    }

    function test_get_round_data_reverts_for_round_zero() public {
        vm.expectRevert(abi.encodeWithSelector(TestnetFeed.UnknownRound.selector, uint80(0)));
        feed.getRoundData(0);
    }

    function test_get_round_data_reverts_past_the_latest_round() public {
        vm.expectRevert(abi.encodeWithSelector(TestnetFeed.UnknownRound.selector, uint80(2)));
        feed.getRoundData(2);
        feed.set(210e8, START + 60);
        (uint80 roundId,,,,) = feed.getRoundData(2);
        assertEq(roundId, 2);
    }

    function test_a_round_set_with_time_zero_is_still_recorded() public {
        feed.set(210e8, 0);
        (uint80 roundId, int256 answer,, uint256 updatedAt,) = feed.getRoundData(2);
        assertEq(roundId, 2);
        assertEq(answer, 210e8);
        assertEq(updatedAt, 0);
    }

    function test_set_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        feed.set(210e8, START + 60);
    }

    /// A StockIndexFeed on the stand-in walks its rounds: a clean move syncs, a move of more than
    /// 30% latches the breaker.
    function test_stock_index_feed_walks_the_recorded_rounds() public {
        MarketCalendar calendar = new MarketCalendar(address(this));
        address[] memory feeds = new address[](1);
        feeds[0] = address(feed);
        StockIndexFeed index = new StockIndexFeed(
            "Kyzen Network Design index / USD", IMarketCalendar(address(calendar)), feeds, address(this)
        );
        assertEq(index.checkedRound(0), 1);

        feed.set(220e8, block.timestamp); // +10%
        assertFalse(index.jumped(0));
        index.sync();
        assertEq(index.checkedRound(0), 2);

        feed.set(300e8, block.timestamp); // +36%
        assertTrue(index.jumped(0));
        index.sync();
        assertEq(index.checkedRound(0), 2);
    }
}
