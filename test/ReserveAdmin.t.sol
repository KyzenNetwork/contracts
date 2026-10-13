// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Reserve} from "../src/Reserve.sol";
import {IKyzn} from "../src/interfaces/IKyzn.sol";
import {IRotationState} from "../src/interfaces/IRotationState.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {Fixture} from "./utils/Fixture.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {HostileToken} from "./mocks/HostileToken.sol";
import {MalformedFeed} from "./mocks/MalformedFeed.sol";

contract SixDecimals is ERC20 {
    constructor() ERC20("Six", "SIX") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

/// A feed whose answer can no longer be read, as a retired feed might behave.
contract DeadFeed {
    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external pure returns (uint80, int256, uint256, uint256, uint80) {
        revert("DeadFeed");
    }
}

/// Reserve owner powers and value views (SPEC 3.2).
contract ReserveAdminTest is Fixture {
    /// Gas for a view that meets an asset whose balanceOf burns all it gets.
    uint256 internal constant VIEW_GAS = 3_000_000;

    function test_assets_are_listed_with_their_stage() public view {
        assertEq(reserve.assetCount(), 3);
        assertEq(reserve.assets(2), address(mu));
        (address feed, uint8 feedDecimals, uint8 stage, uint64 lastTradeAt, bool listed) =
            reserve.assetInfo(address(mu));
        assertEq(feed, address(muFeed));
        assertEq(feedDecimals, 8);
        assertEq(stage, 1);
        assertEq(lastTradeAt, 0);
        assertTrue(listed);
    }

    function test_addAsset_rules() public {
        MockStockToken tsm = new MockStockToken("TSM");
        MockFeed feed = new MockFeed(8, 180e8);
        vm.expectRevert(Reserve.AssetListed.selector);
        reserve.addAsset(address(nvda), address(feed), 0);
        vm.expectRevert(Reserve.BadStage.selector);
        reserve.addAsset(address(tsm), address(feed), 5);
        vm.expectRevert(Reserve.BadAsset.selector);
        reserve.addAsset(address(token), address(feed), 2);
        vm.expectRevert(Reserve.BadAsset.selector);
        reserve.addAsset(address(weth), address(feed), 2);
        vm.expectRevert(Reserve.ZeroAddress.selector);
        reserve.addAsset(address(tsm), address(0), 2);
        SixDecimals six = new SixDecimals();
        vm.expectRevert(Reserve.BadAsset.selector);
        reserve.addAsset(address(six), address(feed), 2);
        MockFeed wideFeed = new MockFeed(19, 1);
        vm.expectRevert(Reserve.BadFeed.selector);
        reserve.addAsset(address(tsm), address(wideFeed), 2);

        vm.expectEmit(address(reserve));
        emit Reserve.AssetQueued(address(tsm), address(feed), 2, block.timestamp + 24 hours);
        reserve.addAsset(address(tsm), address(feed), 2);
        assertEq(reserve.assetCount(), 3);
    }

    function test_at_most_16_assets() public {
        MockFeed feed = new MockFeed(8, 100e8);
        for (uint256 i = 3; i < 16; ++i) {
            _listNow(address(new MockStockToken("X")), address(feed), 3);
        }
        MockStockToken seventeenth = new MockStockToken("X");
        vm.expectRevert(Reserve.TooManyAssets.selector);
        reserve.addAsset(address(seventeenth), address(feed), 3);
    }

    function test_the_constructor_rejects_zero_addresses_and_a_feed_above_18_decimals() public {
        IKyzn kyzn = IKyzn(address(token));
        IWETH w = IWETH(address(weth));
        IRotationState reg = IRotationState(address(registry));
        Reserve.AssetConfig[] memory none = new Reserve.AssetConfig[](0);
        vm.expectRevert(Reserve.ZeroAddress.selector);
        new Reserve(IKyzn(address(0)), w, address(ethUsd), reg, none);
        vm.expectRevert(Reserve.ZeroAddress.selector);
        new Reserve(kyzn, IWETH(address(0)), address(ethUsd), reg, none);
        vm.expectRevert(Reserve.ZeroAddress.selector);
        new Reserve(kyzn, w, address(0), reg, none);
        vm.expectRevert(Reserve.ZeroAddress.selector);
        new Reserve(kyzn, w, address(ethUsd), IRotationState(address(0)), none);
        MockFeed wide = new MockFeed(19, 2_500e19);
        vm.expectRevert(Reserve.BadFeed.selector);
        new Reserve(kyzn, w, address(wide), reg, none);
        // 18 decimals is the widest ETH/USD feed accepted.
        Reserve fresh = new Reserve(kyzn, w, address(new MockFeed(18, 2_500e18)), reg, none);
        assertEq(fresh.ethUsdDecimals(), 18);
        assertEq(fresh.assetCount(), 0);
    }

    /// Each initial asset is listed at once, announced as listAsset announces a listing.
    function test_the_constructor_announces_each_initial_asset() public {
        Reserve.AssetConfig[] memory initial = new Reserve.AssetConfig[](3);
        initial[0] = Reserve.AssetConfig({token: address(nvda), feed: address(nvdaFeed), stage: 0});
        initial[1] = Reserve.AssetConfig({token: address(amd), feed: address(amdFeed), stage: 0});
        initial[2] = Reserve.AssetConfig({token: address(mu), feed: address(muFeed), stage: 1});
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        for (uint256 i; i < initial.length; ++i) {
            vm.expectEmit(predicted);
            emit Reserve.AssetAdded(initial[i].token, initial[i].feed, initial[i].stage);
        }
        Reserve fresh = new Reserve(
            IKyzn(address(token)), IWETH(address(weth)), address(ethUsd), IRotationState(address(registry)), initial
        );
        assertEq(address(fresh), predicted);
        assertEq(fresh.assetCount(), 3);
        for (uint256 i; i < initial.length; ++i) {
            assertEq(fresh.assets(i), initial[i].token);
        }
    }

    /// The constructor checks its initial assets by the same rules as addAsset.
    function test_the_constructor_checks_its_initial_assets() public {
        Reserve.AssetConfig[] memory bad = new Reserve.AssetConfig[](1);
        bad[0] = Reserve.AssetConfig({token: address(new SixDecimals()), feed: address(nvdaFeed), stage: 0});
        vm.expectRevert(Reserve.BadAsset.selector);
        new Reserve(
            IKyzn(address(token)), IWETH(address(weth)), address(ethUsd), IRotationState(address(registry)), bad
        );
        bad[0] = Reserve.AssetConfig({token: address(nvda), feed: address(nvdaFeed), stage: 5});
        vm.expectRevert(Reserve.BadStage.selector);
        new Reserve(
            IKyzn(address(token)), IWETH(address(weth)), address(ethUsd), IRotationState(address(registry)), bad
        );
        Reserve.AssetConfig[] memory twice = new Reserve.AssetConfig[](2);
        twice[0] = Reserve.AssetConfig({token: address(nvda), feed: address(nvdaFeed), stage: 0});
        twice[1] = twice[0];
        vm.expectRevert(Reserve.AssetListed.selector);
        new Reserve(
            IKyzn(address(token)), IWETH(address(weth)), address(ethUsd), IRotationState(address(registry)), twice
        );
    }

    function test_a_listing_waits_24_hours_then_needs_listAsset() public {
        MockStockToken tsm = new MockStockToken("TSM");
        MockFeed feed = new MockFeed(8, 180e8);
        vm.expectEmit(address(reserve));
        emit Reserve.AssetQueued(address(tsm), address(feed), 2, MONDAY_1400 + 24 hours);
        reserve.addAsset(address(tsm), address(feed), 2);
        (address pendingFeed, uint8 pendingStage, uint64 effectiveAt) = reserve.pendingAsset(address(tsm));
        assertEq(pendingFeed, address(feed));
        assertEq(pendingStage, 2);
        assertEq(effectiveAt, MONDAY_1400 + 24 hours);
        (,,,, bool listed) = reserve.assetInfo(address(tsm));
        assertFalse(listed);
        assertEq(reserve.assetCount(), 3);

        vm.warp(MONDAY_1400 + 24 hours - 1);
        vm.expectRevert(Reserve.TooSoon.selector);
        reserve.listAsset(address(tsm));

        vm.warp(MONDAY_1400 + 24 hours);
        vm.expectEmit(address(reserve));
        emit Reserve.AssetAdded(address(tsm), address(feed), 2);
        reserve.listAsset(address(tsm));
        (address feedAddress, uint8 feedDecimals, uint8 stage, uint64 lastTradeAt, bool nowListed) =
            reserve.assetInfo(address(tsm));
        assertEq(feedAddress, address(feed));
        assertEq(feedDecimals, 8);
        assertEq(stage, 2);
        assertEq(lastTradeAt, 0);
        assertTrue(nowListed);
        assertEq(reserve.assetCount(), 4);
        assertEq(reserve.assets(3), address(tsm));
        (,, effectiveAt) = reserve.pendingAsset(address(tsm));
        assertEq(effectiveAt, 0);
        vm.expectRevert(Reserve.NotPending.selector);
        reserve.listAsset(address(tsm));
    }

    function test_pending_listing_can_be_cancelled() public {
        MockStockToken tsm = new MockStockToken("TSM");
        MockFeed feed = new MockFeed(8, 180e8);
        reserve.addAsset(address(tsm), address(feed), 2);
        vm.expectEmit(address(reserve));
        emit Reserve.AssetCancelled(address(tsm));
        reserve.cancelAsset(address(tsm));
        (address pendingFeed,, uint64 effectiveAt) = reserve.pendingAsset(address(tsm));
        assertEq(pendingFeed, address(0));
        assertEq(effectiveAt, 0);

        vm.warp(MONDAY_1400 + 24 hours);
        vm.expectRevert(Reserve.NotPending.selector);
        reserve.listAsset(address(tsm));
        vm.expectRevert(Reserve.NotPending.selector);
        reserve.cancelAsset(address(tsm));
        (,,,, bool listed) = reserve.assetInfo(address(tsm));
        assertFalse(listed);

        // Queued again, the new listing waits its own 24 hours.
        reserve.addAsset(address(tsm), address(feed), 3);
        uint8 stage;
        (, stage, effectiveAt) = reserve.pendingAsset(address(tsm));
        assertEq(stage, 3);
        assertEq(effectiveAt, MONDAY_1400 + 48 hours);
    }

    function test_a_pending_asset_cannot_be_queued_twice() public {
        MockStockToken tsm = new MockStockToken("TSM");
        MockFeed feed = new MockFeed(8, 180e8);
        reserve.addAsset(address(tsm), address(feed), 2);
        vm.warp(MONDAY_1400 + 12 hours);
        vm.expectRevert(Reserve.AssetPending.selector);
        reserve.addAsset(address(tsm), address(feed), 3);
        (, uint8 stage, uint64 effectiveAt) = reserve.pendingAsset(address(tsm));
        assertEq(stage, 2);
        assertEq(effectiveAt, MONDAY_1400 + 24 hours);
    }

    function test_listing_rechecks_the_16_asset_capacity() public {
        MockFeed feed = new MockFeed(8, 100e8);
        address[] memory queued = new address[](14);
        for (uint256 i; i < queued.length; ++i) {
            queued[i] = address(new MockStockToken("X"));
            reserve.addAsset(queued[i], address(feed), 3); // three listed: each fits when queued
        }
        vm.warp(MONDAY_1400 + 24 hours);
        for (uint256 i; i < 13; ++i) {
            reserve.listAsset(queued[i]);
        }
        assertEq(reserve.assetCount(), 16);
        vm.expectRevert(Reserve.TooManyAssets.selector);
        reserve.listAsset(queued[13]);
        MockStockToken another = new MockStockToken("Y");
        vm.expectRevert(Reserve.TooManyAssets.selector);
        reserve.addAsset(address(another), address(feed), 3);
    }

    function test_pending_asset_is_not_valued() public {
        MockStockToken tsm = new MockStockToken("TSM");
        reserve.addAsset(address(tsm), address(new MockFeed(8, 180e8)), 2);
        tsm.mint(address(reserve), 10e18); // $1,800 once listed
        nvda.mint(address(reserve), 10e18); // $2,000
        (uint256 value,) = reserve.reserveValue();
        assertEq(value, 2_000e18);
        vm.warp(MONDAY_1400 + 24 hours);
        reserve.listAsset(address(tsm));
        (value,) = reserve.reserveValue();
        assertEq(value, 3_800e18);
    }

    function test_owner_powers_are_owner_only() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(unauthorized);
        reserve.setKeeper(alice);
        vm.expectRevert(unauthorized);
        reserve.addAsset(address(1), address(2), 0);
        vm.expectRevert(unauthorized);
        reserve.listAsset(address(1));
        vm.expectRevert(unauthorized);
        reserve.cancelAsset(address(1));
        vm.expectRevert(unauthorized);
        reserve.queueTarget(address(3), true);
        vm.stopPrank();
    }

    function test_setKeeper() public {
        vm.expectEmit(address(reserve));
        emit Reserve.KeeperSet(bob);
        reserve.setKeeper(bob);
        assertEq(reserve.keeper(), bob);
    }

    function test_target_changes_take_24_hours() public {
        address venue = makeAddr("venue");
        reserve.queueTarget(venue, true);
        assertFalse(reserve.isTargetAllowed(venue));
        vm.warp(block.timestamp + 24 hours - 1);
        assertFalse(reserve.isTargetAllowed(venue));
        vm.warp(block.timestamp + 1);
        assertTrue(reserve.isTargetAllowed(venue));

        reserve.queueTarget(venue, false); // removal waits 24 hours too
        assertTrue(reserve.isTargetAllowed(venue));
        vm.warp(block.timestamp + 24 hours);
        assertFalse(reserve.isTargetAllowed(venue));
    }

    function test_requeue_restarts_the_delay() public {
        address venue = makeAddr("venue");
        reserve.queueTarget(venue, true);
        vm.warp(block.timestamp + 12 hours);
        reserve.queueTarget(venue, true);
        vm.warp(block.timestamp + 12 hours);
        assertFalse(reserve.isTargetAllowed(venue));
        vm.warp(block.timestamp + 12 hours);
        assertTrue(reserve.isTargetAllowed(venue));
    }

    function test_target_cannot_be_a_token_the_reserve_holds() public {
        vm.expectRevert(Reserve.BadTarget.selector);
        reserve.queueTarget(address(0), true);
        vm.expectRevert(Reserve.BadTarget.selector);
        reserve.queueTarget(address(token), true);
        vm.expectRevert(Reserve.BadTarget.selector);
        reserve.queueTarget(address(weth), true);
        vm.expectRevert(Reserve.BadTarget.selector);
        reserve.queueTarget(address(nvda), true);
    }

    function test_target_rule_forbids_the_protocol_contracts_and_every_asset() public {
        MockStockToken tsm = new MockStockToken("TSM");
        reserve.addAsset(address(tsm), address(new MockFeed(8, 180e8)), 2); // pending
        address[10] memory forbidden = [
            address(0),
            address(token),
            address(weth),
            pair,
            address(reserve),
            address(staking),
            address(nvda),
            address(amd),
            address(mu),
            address(tsm)
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.expectRevert(Reserve.BadTarget.selector);
            reserve.queueTarget(forbidden[i], true);
            assertFalse(reserve.isTargetAllowed(forbidden[i]));
        }
    }

    function test_a_target_that_becomes_an_asset_is_no_longer_allowed() public {
        MockStockToken tsm = new MockStockToken("TSM");
        MockFeed tsmFeed = new MockFeed(8, 180e8);
        reserve.queueTarget(address(tsm), true);
        vm.warp(MONDAY_1400 + 24 hours); // Tuesday 14:00 UTC: tsm is a live target
        assertTrue(reserve.isTargetAllowed(address(tsm)));

        reserve.addAsset(address(tsm), address(tsmFeed), 2); // pending
        assertFalse(reserve.isTargetAllowed(address(tsm)));
        vm.deal(address(reserve), 1 ether);
        _refreshFeeds();
        vm.prank(keeper);
        vm.expectRevert(Reserve.BadTarget.selector);
        reserve.buy(address(nvda), address(tsm), "", 0.1 ether, 0);

        reserve.cancelAsset(address(tsm)); // no longer pending: the allowlist applies again
        assertTrue(reserve.isTargetAllowed(address(tsm)));

        reserve.addAsset(address(tsm), address(tsmFeed), 2);
        vm.warp(block.timestamp + 24 hours);
        reserve.listAsset(address(tsm));
        assertFalse(reserve.isTargetAllowed(address(tsm)));
    }

    function test_reserve_value_and_backing() public {
        vm.deal(address(reserve), 2 ether); // $5,000
        nvda.mint(address(reserve), 10e18); // $2,000
        mu.mint(address(reserve), 30e18); // $3,000
        (uint256 value, uint256 oldest) = reserve.reserveValue();
        assertEq(value, 10_000e18);
        assertEq(oldest, MONDAY_1400);
        (uint256 perToken,) = reserve.backingPerToken();
        assertEq(perToken, 10_000e18 * 1e18 / 1_000_000_000e18);
    }

    function test_weth_counts_as_eth() public {
        vm.deal(address(this), 1 ether);
        weth.deposit{value: 1 ether}();
        weth.transfer(address(reserve), 1 ether);
        (uint256 value,) = reserve.reserveValue();
        assertEq(value, 2_500e18);
    }

    function test_oldest_update_tracks_the_stalest_feed() public {
        nvda.mint(address(reserve), 1e18);
        vm.warp(MONDAY_1400 + 1 hours);
        ethUsd.set(2_500e8, block.timestamp);
        (, uint256 oldest) = reserve.reserveValue();
        assertEq(oldest, MONDAY_1400);
    }

    function test_views_leave_out_an_unreadable_balance_and_flag_it() public {
        vm.deal(address(reserve), 2 ether); // $5,000
        nvda.mint(address(reserve), 10e18); // $2,000
        mu.mint(address(reserve), 30e18); // $3,000
        HostileToken hostile = new HostileToken();
        _listNow(address(hostile), address(new MockFeed(8, 100e8)), 2);
        hostile.mint(address(reserve), 50e18); // $5,000 while readable
        (uint256 value, uint256 oldest) = reserve.reserveValue();
        assertEq(value, 15_000e18);
        assertEq(oldest, MONDAY_1400);

        HostileToken.Mode[4] memory modes = [
            HostileToken.Mode.Revert,
            HostileToken.Mode.BurnGas,
            HostileToken.Mode.ShortAnswer,
            HostileToken.Mode.AnswerHuge
        ];
        for (uint256 i; i < modes.length; ++i) {
            hostile.setBalanceMode(modes[i]);
            (value, oldest) = reserve.reserveValue{gas: VIEW_GAS}();
            assertEq(value, 10_000e18);
            assertEq(oldest, 0);
            (uint256 perToken, uint256 flag) = reserve.backingPerToken{gas: VIEW_GAS}();
            assertEq(perToken, 0.00001e18); // $10,000 over 1,000,000,000 $KYZN
            assertEq(flag, 0);
        }
    }

    /// Fix round item 1: a feed that answers with too few bytes, with nothing, or that burns
    /// all the gas it is given is unreadable the same as a reverting one: the views leave its
    /// holding out and flag oldestUpdate, instead of reverting (try/catch cannot catch a
    /// decode failure that happens outside the external call itself).
    function test_views_leave_out_an_asset_with_a_malformed_feed_answer() public {
        vm.deal(address(reserve), 2 ether); // $5,000
        nvda.mint(address(reserve), 10e18); // $2,000
        mu.mint(address(reserve), 30e18); // $3,000
        MalformedFeed bad = new MalformedFeed(8, 100e8);
        MockStockToken tsm = new MockStockToken("TSM");
        _listNow(address(tsm), address(bad), 2);
        tsm.mint(address(reserve), 10e18); // $1,000 while the feed still answers normally

        MalformedFeed.Mode[3] memory modes =
            [MalformedFeed.Mode.ShortAnswer, MalformedFeed.Mode.AnswerNothing, MalformedFeed.Mode.BurnGas];
        for (uint256 i; i < modes.length; ++i) {
            bad.setMode(modes[i]);
            (uint256 value, uint256 oldest) = reserve.reserveValue{gas: VIEW_GAS}();
            assertEq(value, 10_000e18);
            assertEq(oldest, 0);
            (uint256 perToken, uint256 flag) = reserve.backingPerToken{gas: VIEW_GAS}();
            assertEq(perToken, 0.00001e18); // $10,000 over 1,000,000,000 $KYZN
            assertEq(flag, 0);
        }
    }

    function test_views_leave_out_a_held_asset_whose_price_cannot_be_read() public {
        vm.deal(address(reserve), 2 ether); // $5,000
        nvda.mint(address(reserve), 10e18); // $2,000
        mu.mint(address(reserve), 30e18); // $3,000
        int256[3] memory badAnswers = [int256(0), -1, type(int256).max]; // the last overflows at 18 decimals
        for (uint256 i; i < badAnswers.length; ++i) {
            nvdaFeed.set(badAnswers[i], MONDAY_1400);
            (uint256 value, uint256 oldest) = reserve.reserveValue();
            assertEq(value, 8_000e18);
            assertEq(oldest, 0);
        }
        nvdaFeed.set(200e8, MONDAY_1400);

        MockStockToken tsm = new MockStockToken("TSM");
        _listNow(address(tsm), address(new DeadFeed()), 2);
        tsm.mint(address(reserve), 1e18);
        (uint256 total, uint256 flag) = reserve.reserveValue();
        assertEq(total, 10_000e18);
        assertEq(flag, 0);
        (uint256 perToken, uint256 backingFlag) = reserve.backingPerToken();
        assertEq(perToken, 0.00001e18);
        assertEq(backingFlag, 0);
    }

    function test_views_leave_out_eth_when_the_eth_feed_cannot_be_read() public {
        vm.deal(address(reserve), 2 ether);
        nvda.mint(address(reserve), 10e18); // $2,000
        ethUsd.set(0, MONDAY_1400);
        (uint256 value, uint256 oldest) = reserve.reserveValue();
        assertEq(value, 2_000e18);
        assertEq(oldest, 0);
    }

    function test_views_use_the_last_published_price_whatever_its_age() public {
        nvda.mint(address(reserve), 10e18);
        vm.warp(MONDAY_1400 + 3 days);
        (uint256 value, uint256 oldest) = reserve.reserveValue();
        assertEq(value, 2_000e18);
        assertEq(oldest, MONDAY_1400);
    }

    function test_a_broken_feed_on_an_asset_not_held_is_not_flagged() public {
        nvda.mint(address(reserve), 10e18);
        amdFeed.set(0, MONDAY_1400); // no AMD held
        (uint256 value, uint256 oldest) = reserve.reserveValue();
        assertEq(value, 2_000e18);
        assertEq(oldest, MONDAY_1400);
    }

    function test_receives_eth() public {
        (bool ok,) = address(reserve).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(reserve).balance, 1 ether);
    }

    /// Trading and redemption are open from deployment.
    function test_redemption_works_from_deployment() public {
        token.transfer(alice, 1_000e18);
        uint256 supply = token.totalSupply();
        vm.startPrank(alice);
        token.approve(address(reserve), 1_000e18);
        reserve.redeem(1_000e18);
        vm.stopPrank();
        assertEq(token.totalSupply(), supply - 1_000e18);
    }
}
