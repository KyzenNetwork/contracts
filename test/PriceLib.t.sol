// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {PriceLib} from "../src/lib/PriceLib.sol";
import {MockFeed} from "./mocks/MockFeed.sol";

/// External entry points so reverts happen one call below the test.
contract PriceLibHarness {
    function inWindow(uint256 timestamp) external pure returns (bool) {
        return PriceLib.inPurchaseWindow(timestamp);
    }

    function latest(address feed, uint8 feedDecimals) external view returns (uint256, uint256) {
        return PriceLib.latest(feed, feedDecimals);
    }

    function fresh(address feed, uint8 feedDecimals, uint256 maxAge) external view returns (uint256) {
        return PriceLib.fresh(feed, feedDecimals, maxAge);
    }
}

/// The purchase window and Chainlink reads (SPEC 3.2 buy discipline).
contract PriceLibTest is Test {
    uint256 internal constant MONDAY_0000 = 1_790_553_600; // Monday 28 September 2026, 00:00 UTC
    PriceLibHarness internal h = new PriceLibHarness();

    function test_window_opens_at_1330_and_closes_before_2100() public view {
        assertFalse(h.inWindow(MONDAY_0000 + 13 hours + 29 minutes + 59));
        assertTrue(h.inWindow(MONDAY_0000 + 13 hours + 30 minutes));
        assertTrue(h.inWindow(MONDAY_0000 + 20 hours + 59 minutes + 59));
        assertFalse(h.inWindow(MONDAY_0000 + 21 hours));
    }

    function test_window_is_monday_to_friday() public view {
        for (uint256 day; day < 7; ++day) {
            assertEq(h.inWindow(MONDAY_0000 + day * 1 days + 14 hours), day < 5);
        }
    }

    function testFuzz_window_matches_the_calendar(uint256 timestamp) public view {
        timestamp = bound(timestamp, MONDAY_0000, MONDAY_0000 + 520 weeks);
        uint256 dayFromMonday = ((timestamp - MONDAY_0000) / 1 days) % 7;
        uint256 second = timestamp % 1 days;
        bool expected = dayFromMonday < 5 && second >= 48_600 && second < 75_600;
        assertEq(h.inWindow(timestamp), expected);
    }

    function test_latest_scales_to_18_decimals() public {
        MockFeed feed = new MockFeed(8, 2_500e8);
        (uint256 price, uint256 updatedAt) = h.latest(address(feed), 8);
        assertEq(price, 2_500e18);
        assertEq(updatedAt, block.timestamp);
    }

    function test_non_positive_answer_reverts() public {
        MockFeed feed = new MockFeed(8, 0);
        vm.expectRevert(abi.encodeWithSelector(PriceLib.BadPrice.selector, address(feed)));
        h.latest(address(feed), 8);
        feed.set(-1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(PriceLib.BadPrice.selector, address(feed)));
        h.latest(address(feed), 8);
    }

    function test_fresh_accepts_exactly_max_age() public {
        vm.warp(MONDAY_0000 + 14 hours);
        MockFeed feed = new MockFeed(8, 200e8);
        feed.set(200e8, block.timestamp - 24 hours);
        assertEq(h.fresh(address(feed), 8, 24 hours), 200e18);
        feed.set(200e8, block.timestamp - 24 hours - 1);
        vm.expectRevert(abi.encodeWithSelector(PriceLib.StalePrice.selector, address(feed)));
        h.fresh(address(feed), 8, 24 hours);
    }
}
