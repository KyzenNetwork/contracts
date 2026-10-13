// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SiliconFeed} from "../../src/silicon/SiliconFeed.sol";

/// The attested feed (SPEC 3.5): reports wait out a dispute window, the guardian can reject within
/// it, a price ages from its report.
contract SiliconFeedTest is Test {
    uint256 internal constant WINDOW = 30 minutes;
    uint256 internal constant MAX_AGE = 2 hours;
    bytes32 internal constant SOURCES = keccak256("sources: vast.ai, runpod, lambda 2026-10-02T14:00Z");
    bytes32 internal constant SOURCES_2 = keccak256("sources: second report");

    address internal reporter = makeAddr("reporter");
    address internal guardian = makeAddr("guardian");
    address internal alice = makeAddr("alice");
    SiliconFeed internal feed;

    function setUp() public {
        vm.warp(1_790_604_000);
        feed = new SiliconFeed("H100-HR / USD", WINDOW, MAX_AGE);
        feed.setReporter(reporter);
        feed.setGuardian(guardian);
    }

    function _report(uint256 price, bytes32 sources) internal {
        vm.prank(reporter);
        feed.report(price, sources);
    }

    // ---------------------------------------------------------------- construction and roles

    function test_constructor() public view {
        assertEq(feed.description(), "H100-HR / USD");
        assertEq(feed.disputeWindow(), WINDOW);
        assertEq(feed.maxAge(), MAX_AGE);
        assertEq(feed.decimals(), 18);
        assertEq(feed.owner(), address(this));
        (uint256 price, uint256 updatedAt) = feed.latestPrice();
        assertEq(price, 0);
        assertEq(updatedAt, 0);
        assertFalse(feed.isFresh());
    }

    function test_constructor_rejects_zero_window() public {
        vm.expectRevert(SiliconFeed.BadDisputeWindow.selector);
        new SiliconFeed("X", 0, 1 hours);
    }

    /// A price ages from its report, so a maximum age at or below the window would never be fresh.
    function test_constructor_rejects_max_age_not_above_window() public {
        vm.expectRevert(SiliconFeed.BadMaxAge.selector);
        new SiliconFeed("X", 1 hours, 1 hours);
        vm.expectRevert(SiliconFeed.BadMaxAge.selector);
        new SiliconFeed("X", 1 hours, 0);
        new SiliconFeed("X", 1 hours, 1 hours + 1);
    }

    function test_owner_sets_roles_and_methodology() public {
        address other = makeAddr("other");
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        feed.setReporter(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        feed.setGuardian(other);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        feed.setMethodology("https://kyzen.network/docs/silicon/h100-hr", bytes32(uint256(1)));
        vm.stopPrank();

        vm.expectEmit(address(feed));
        emit SiliconFeed.ReporterSet(other);
        feed.setReporter(other);
        assertEq(feed.reporter(), other);

        vm.expectEmit(address(feed));
        emit SiliconFeed.GuardianSet(other);
        feed.setGuardian(other);
        assertEq(feed.guardian(), other);

        bytes32 hash = keccak256("methodology v1");
        vm.expectEmit(address(feed));
        emit SiliconFeed.MethodologySet("https://kyzen.network/docs/silicon/h100-hr", hash);
        feed.setMethodology("https://kyzen.network/docs/silicon/h100-hr", hash);
        assertEq(feed.methodologyURI(), "https://kyzen.network/docs/silicon/h100-hr");
        assertEq(feed.methodologyHash(), hash);
    }

    function test_ownership_moves_in_two_steps() public {
        feed.transferOwnership(alice);
        assertEq(feed.owner(), address(this));
        vm.prank(alice);
        feed.acceptOwnership();
        assertEq(feed.owner(), alice);
    }

    // ---------------------------------------------------------------- reports

    function test_report_rules() public {
        vm.prank(alice);
        vm.expectRevert(SiliconFeed.NotReporter.selector);
        feed.report(2e18, SOURCES);

        vm.startPrank(reporter);
        vm.expectRevert(SiliconFeed.ZeroPrice.selector);
        feed.report(0, SOURCES);
        vm.expectRevert(SiliconFeed.NoSourcesHash.selector);
        feed.report(2e18, bytes32(0));

        vm.expectEmit(address(feed));
        emit SiliconFeed.PriceReported(2e18, SOURCES, block.timestamp + WINDOW);
        feed.report(2e18, SOURCES);
        vm.stopPrank();

        (uint256 price, uint256 reportedAt, bytes32 sources, uint256 finalizesAt) = feed.pendingPrice();
        assertEq(price, 2e18);
        assertEq(reportedAt, block.timestamp);
        assertEq(sources, SOURCES);
        assertEq(finalizesAt, block.timestamp + WINDOW);
    }

    /// Setting the reporter to zero stops reports (no transaction comes from the zero address).
    function test_unset_reporter_stops_reports() public {
        feed.setReporter(address(0));
        vm.prank(reporter);
        vm.expectRevert(SiliconFeed.NotReporter.selector);
        feed.report(2e18, SOURCES);
    }

    /// A posted price is not the price until its window has passed.
    function test_price_is_final_only_after_the_dispute_window() public {
        _report(2e18, SOURCES);
        (uint256 price,) = feed.latestPrice();
        assertEq(price, 0);
        assertFalse(feed.isFresh());

        vm.warp(block.timestamp + WINDOW - 1);
        (price,) = feed.latestPrice();
        assertEq(price, 0);

        vm.warp(block.timestamp + 1);
        uint256 updatedAt;
        (price, updatedAt) = feed.latestPrice();
        assertEq(price, 2e18);
        assertEq(updatedAt, block.timestamp - WINDOW);
        assertTrue(feed.isFresh());
        assertEq(feed.latestSourcesHash(), SOURCES);
        (uint256 pending,,,) = feed.pendingPrice();
        assertEq(pending, 0);
    }

    function test_one_price_waits_at_a_time() public {
        _report(2e18, SOURCES);
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(reporter);
        vm.expectRevert(
            abi.encodeWithSelector(SiliconFeed.ReportPending.selector, block.timestamp + WINDOW - 10 minutes)
        );
        feed.report(3e18, SOURCES_2);
    }

    /// The next report records the previous price, once its window has passed.
    function test_report_finalizes_the_previous_price() public {
        uint256 first = block.timestamp;
        _report(2e18, SOURCES);
        vm.warp(block.timestamp + 1 hours);

        vm.expectEmit(address(feed));
        emit SiliconFeed.PriceFinalized(2e18, first, SOURCES);
        vm.expectEmit(address(feed));
        emit SiliconFeed.PriceReported(3e18, SOURCES_2, block.timestamp + WINDOW);
        _report(3e18, SOURCES_2);

        (uint256 price, uint256 updatedAt) = feed.latestPrice();
        assertEq(price, 2e18);
        assertEq(updatedAt, first);
        assertEq(feed.latestSourcesHash(), SOURCES);
    }

    function test_finalize() public {
        vm.expectRevert(SiliconFeed.NothingPending.selector);
        feed.finalize();

        uint256 reportedAt = block.timestamp;
        _report(2e18, SOURCES);
        vm.expectRevert(abi.encodeWithSelector(SiliconFeed.DisputeWindowOpen.selector, reportedAt + WINDOW));
        feed.finalize();

        vm.warp(reportedAt + WINDOW);
        vm.expectEmit(address(feed));
        emit SiliconFeed.PriceFinalized(2e18, reportedAt, SOURCES);
        vm.prank(alice); // anyone
        feed.finalize();
        (uint256 price, uint256 updatedAt) = feed.latestPrice();
        assertEq(price, 2e18);
        assertEq(updatedAt, reportedAt);

        vm.expectRevert(SiliconFeed.NothingPending.selector);
        feed.finalize();
    }

    // ---------------------------------------------------------------- disputes

    function test_guardian_rejects_within_the_window() public {
        _report(2e18, SOURCES);
        vm.warp(block.timestamp + 5 minutes);

        vm.prank(alice);
        vm.expectRevert(SiliconFeed.NotGuardian.selector);
        feed.reject();

        vm.expectEmit(address(feed));
        emit SiliconFeed.PriceRejected(2e18, block.timestamp - 5 minutes, SOURCES);
        vm.prank(guardian);
        feed.reject();

        (uint256 pending,,,) = feed.pendingPrice();
        assertEq(pending, 0);
        vm.warp(block.timestamp + 1 days);
        (uint256 price,) = feed.latestPrice();
        assertEq(price, 0, "a rejected price never becomes final");

        // The reporter posts a corrected price at once.
        _report(2.1e18, SOURCES_2);
        vm.warp(block.timestamp + WINDOW);
        (price,) = feed.latestPrice();
        assertEq(price, 2.1e18);
    }

    function test_rejection_keeps_the_previous_price() public {
        _report(2e18, SOURCES);
        vm.warp(block.timestamp + WINDOW);
        _report(9e18, SOURCES_2); // a bad print
        vm.prank(guardian);
        feed.reject();
        vm.warp(block.timestamp + WINDOW);
        (uint256 price,) = feed.latestPrice();
        assertEq(price, 2e18);
    }

    function test_guardian_cannot_reject_after_the_window() public {
        uint256 reportedAt = block.timestamp;
        _report(2e18, SOURCES);
        vm.warp(reportedAt + WINDOW);
        vm.prank(guardian);
        vm.expectRevert(abi.encodeWithSelector(SiliconFeed.DisputeWindowClosed.selector, reportedAt + WINDOW));
        feed.reject();
    }

    function test_reject_with_nothing_pending() public {
        vm.prank(guardian);
        vm.expectRevert(SiliconFeed.NothingPending.selector);
        feed.reject();
    }

    // ---------------------------------------------------------------- freshness

    /// A price is fresh for maxAge seconds from its report, the dispute window included.
    function test_stale_after_max_age_from_the_report() public {
        uint256 reportedAt = block.timestamp;
        _report(2e18, SOURCES);
        vm.warp(reportedAt + MAX_AGE);
        assertTrue(feed.isFresh());
        vm.warp(reportedAt + MAX_AGE + 1);
        assertFalse(feed.isFresh());
        (uint256 price, uint256 updatedAt) = feed.latestPrice();
        assertEq(price, 2e18, "a stale price is still the latest");
        assertEq(updatedAt, reportedAt);
    }

    /// Hourly reports with a 30-minute window keep the feed fresh at every second.
    function test_hourly_reports_stay_fresh() public {
        _report(2e18, SOURCES);
        vm.warp(block.timestamp + WINDOW);
        for (uint256 i; i < 48; ++i) {
            vm.warp(block.timestamp + 30 minutes);
            _report(2e18 + i, SOURCES);
            assertTrue(feed.isFresh());
            vm.warp(block.timestamp + 30 minutes);
            assertTrue(feed.isFresh());
        }
    }

    /// Liquidation freshness is the same as freshness for this feed, before the first price, at
    /// the maximum age and past it.
    function test_isFreshForLiquidation_equals_isFresh() public {
        assertFalse(feed.isFresh());
        assertEq(feed.isFreshForLiquidation(), feed.isFresh(), "no price yet");

        uint256 reportedAt = block.timestamp;
        _report(2e18, SOURCES);
        assertEq(feed.isFreshForLiquidation(), feed.isFresh(), "in the dispute window");
        vm.warp(reportedAt + WINDOW);
        assertTrue(feed.isFreshForLiquidation());
        assertEq(feed.isFreshForLiquidation(), feed.isFresh(), "final");
        vm.warp(reportedAt + MAX_AGE);
        assertTrue(feed.isFreshForLiquidation());
        assertEq(feed.isFreshForLiquidation(), feed.isFresh(), "at the maximum age");
        vm.warp(reportedAt + MAX_AGE + 1);
        assertFalse(feed.isFreshForLiquidation());
        assertEq(feed.isFreshForLiquidation(), feed.isFresh(), "past the maximum age");
    }

    /// An attested feed has no rounds to check: sync() does nothing, for anyone.
    function test_sync_does_nothing() public {
        _report(2e18, SOURCES);
        (uint256 price, uint256 updatedAt) = feed.latestPrice();
        vm.recordLogs();
        vm.prank(alice);
        feed.sync();
        assertEq(vm.getRecordedLogs().length, 0);
        (uint256 priceAfter, uint256 updatedAtAfter) = feed.latestPrice();
        assertEq(priceAfter, price);
        assertEq(updatedAtAfter, updatedAt);
    }

    // ---------------------------------------------------------------- readiness

    /// The feed may back an open market once the reporter, the guardian and the methodology are
    /// all set; a missing one, or one taken back, keeps it closed.
    function test_ready_needs_reporter_guardian_and_methodology() public {
        SiliconFeed f = new SiliconFeed("B200-HR / USD", WINDOW, MAX_AGE);
        assertFalse(f.ready());
        f.setReporter(reporter);
        assertFalse(f.ready(), "reporter only");
        f.setGuardian(guardian);
        assertFalse(f.ready(), "no methodology");
        f.setMethodology("https://kyzen.network/docs/silicon/b200-hr", keccak256("methodology"));
        assertTrue(f.ready());

        f.setReporter(address(0));
        assertFalse(f.ready(), "reporter taken back");
        f.setReporter(reporter);
        assertTrue(f.ready());
        f.setGuardian(address(0));
        assertFalse(f.ready(), "guardian taken back");
        f.setGuardian(guardian);
        f.setMethodology("", bytes32(0));
        assertFalse(f.ready(), "methodology taken back");
    }

    /// Each pair of roles without the third is not ready.
    function test_ready_needs_each_of_the_three() public {
        SiliconFeed noReporter = new SiliconFeed("X", WINDOW, MAX_AGE);
        noReporter.setGuardian(guardian);
        noReporter.setMethodology("uri", keccak256("m"));
        assertFalse(noReporter.ready());

        SiliconFeed noGuardian = new SiliconFeed("X", WINDOW, MAX_AGE);
        noGuardian.setReporter(reporter);
        noGuardian.setMethodology("uri", keccak256("m"));
        assertFalse(noGuardian.ready());

        SiliconFeed noMethodology = new SiliconFeed("X", WINDOW, MAX_AGE);
        noMethodology.setReporter(reporter);
        noMethodology.setGuardian(guardian);
        assertFalse(noMethodology.ready());
    }

    function testFuzz_latest_price_follows_the_window(uint256 window, uint256 extraAge, uint256 elapsed) public {
        window = bound(window, 1, 30 days);
        uint256 maxAge = window + bound(extraAge, 1, 30 days);
        elapsed = bound(elapsed, 0, maxAge * 2);
        SiliconFeed f = new SiliconFeed("X", window, maxAge);
        f.setReporter(reporter);
        uint256 reportedAt = block.timestamp;
        vm.prank(reporter);
        f.report(7e18, SOURCES);
        vm.warp(reportedAt + elapsed);

        (uint256 price, uint256 updatedAt) = f.latestPrice();
        if (elapsed < window) {
            assertEq(price, 0);
            assertFalse(f.isFresh());
        } else {
            assertEq(price, 7e18);
            assertEq(updatedAt, reportedAt);
            assertEq(f.isFresh(), elapsed <= maxAge);
        }
    }
}
