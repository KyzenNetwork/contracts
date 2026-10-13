// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Staking} from "../src/Staking.sol";
import {PriceLib} from "../src/lib/PriceLib.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {Fixture} from "./utils/Fixture.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockVenue} from "./mocks/MockVenue.sol";

/// Payout modes: ETH, Compound (tax-free buy) and chip equity behind a switch (SPEC 3.3).
contract StakingPayoutTest is Fixture {
    uint256 internal reward;

    function setUp() public override {
        super.setUp();
        token.transfer(alice, 10_000_000e18);
        _launch();
        token.removeMaxWallet();
        vm.startPrank(alice);
        token.approve(address(staking), type(uint256).max);
        staking.stake(1_000_000e18);
        vm.stopPrank();
        _taxEthToStaking(0.01 ether);
        staking.notifyRewards();
        vm.warp(block.timestamp + 24 hours); // Tuesday 14:00 UTC, the stream has ended
        reward = staking.earned(alice);
    }

    function test_default_mode_is_eth() public view {
        assertEq(uint8(staking.payoutMode(alice)), uint8(Staking.PayoutMode.Eth));
    }

    function test_stakers_choose_compound() public {
        vm.prank(alice);
        staking.setPayoutMode(Staking.PayoutMode.Compound);
        assertEq(uint8(staking.payoutMode(alice)), uint8(Staking.PayoutMode.Compound));
    }

    function test_equity_mode_needs_the_switch() public {
        vm.prank(alice);
        vm.expectRevert(Staking.EquityDisabled.selector);
        staking.setPayoutMode(Staking.PayoutMode.Equity);
        staking.setEquityEnabled(true);
        vm.prank(alice);
        staking.setPayoutMode(Staking.PayoutMode.Equity);
        assertEq(uint8(staking.payoutMode(alice)), uint8(Staking.PayoutMode.Equity));
    }

    function test_the_switch_is_owner_only() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        staking.setEquityEnabled(true);
    }

    function test_compound_buys_tax_free_and_stakes() public {
        uint256 taxBefore = token.balanceOf(address(token));
        vm.prank(alice);
        uint256 added = staking.claimCompound(0);
        assertEq(added, reward * router.TOKENS_PER_ETH()); // no 4% taken
        assertEq(staking.stakedOf(alice), 1_000_000e18 + added);
        assertEq(staking.totalStaked(), 1_000_000e18 + added);
        assertEq(token.balanceOf(address(staking)), staking.totalStaked());
        assertEq(token.balanceOf(address(token)), taxBefore);
        assertEq(staking.earned(alice), 0);
    }

    function test_compound_respects_the_minimum() public {
        uint256 tooMuch = reward * router.TOKENS_PER_ETH() + 1;
        vm.prank(alice);
        vm.expectRevert(bytes("MockRouter: slippage"));
        staking.claimCompound(tooMuch);
    }

    function test_equity_claim_is_off_by_default() public {
        vm.prank(alice);
        vm.expectRevert(Staking.EquityDisabled.selector);
        staking.claimEquity(address(nvda), 0, address(0), "", 0);
    }

    /// Enables equity, allows a venue in the Reserve and moves to Wednesday 14:00 UTC.
    function _equityReady() internal returns (MockVenue venue) {
        staking.setEquityEnabled(true);
        venue = new MockVenue(IWETH(address(weth)));
        reserve.queueTarget(address(venue), true);
        vm.warp(block.timestamp + 24 hours);
        _refreshFeeds();
    }

    function _nvdaData(uint256 wethIn) internal view returns (bytes memory) {
        return abi.encodeCall(MockVenue.buyAsset, (nvda, nvdaFeed, ethUsd, wethIn));
    }

    function test_equity_claim_buys_nvda_for_the_staker() public {
        MockVenue venue = _equityReady();
        vm.prank(alice);
        uint256 got = staking.claimEquity(address(nvda), reward, address(venue), _nvdaData(reward), 0);
        assertEq(got, reward * 25 / 2); // $2,500 / $200
        assertEq(nvda.balanceOf(alice), got);
        assertEq(nvda.balanceOf(address(staking)), 0);
        assertEq(staking.earned(alice), 0);
    }

    function test_equity_only_nvda_or_amd() public {
        MockVenue venue = _equityReady();
        vm.prank(alice);
        vm.expectRevert(Staking.BadAsset.selector);
        staking.claimEquity(address(mu), reward, address(venue), _nvdaData(reward), 0);
    }

    function test_equity_target_must_be_live_in_the_reserve() public {
        staking.setEquityEnabled(true);
        MockVenue venue = new MockVenue(IWETH(address(weth)));
        reserve.queueTarget(address(venue), true);
        vm.prank(alice);
        vm.expectRevert(Staking.BadTarget.selector);
        staking.claimEquity(address(nvda), reward, address(venue), _nvdaData(reward), 0);
    }

    function test_equity_target_follows_the_reserve_target_rule() public {
        MockVenue venue = _equityReady();
        address[9] memory forbidden = [
            address(0),
            address(token),
            address(weth),
            pair,
            address(reserve),
            address(staking),
            address(nvda),
            address(amd),
            address(mu)
        ];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.prank(alice);
            vm.expectRevert(Staking.BadTarget.selector);
            staking.claimEquity(address(nvda), reward, forbidden[i], _nvdaData(reward), 0);
        }
        vm.prank(alice);
        assertEq(staking.claimEquity(address(nvda), reward, address(venue), _nvdaData(reward), 0), reward * 25 / 2);
    }

    /// A live Reserve target that is later queued as an asset is forbidden to Staking too.
    function test_equity_refuses_a_live_target_that_became_a_reserve_asset() public {
        staking.setEquityEnabled(true);
        MockStockToken tsm = new MockStockToken("TSM");
        reserve.queueTarget(address(tsm), true);
        vm.warp(block.timestamp + 24 hours); // Wednesday 14:00 UTC: tsm is a live target
        _refreshFeeds();
        reserve.addAsset(address(tsm), address(new MockFeed(8, 180e8)), 2); // pending for 24 hours
        vm.prank(alice);
        vm.expectRevert(Staking.BadTarget.selector);
        staking.claimEquity(address(nvda), reward, address(tsm), abi.encodeCall(IERC20.approve, (alice, 1)), 0);
    }

    function test_equity_in_market_hours_only() public {
        MockVenue venue = _equityReady();
        vm.warp(block.timestamp + 3 days); // Saturday
        _refreshFeeds();
        vm.prank(alice);
        vm.expectRevert(Staking.OutsideWindow.selector);
        staking.claimEquity(address(nvda), reward, address(venue), _nvdaData(reward), 0);
    }

    function test_equity_needs_fresh_feeds() public {
        MockVenue venue = _equityReady();
        nvdaFeed.set(200e8, block.timestamp - 24 hours - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(PriceLib.StalePrice.selector, address(nvdaFeed)));
        staking.claimEquity(address(nvda), reward, address(venue), _nvdaData(reward), 0);
    }

    function test_equity_price_bound() public {
        MockVenue venue = _equityReady();
        venue.setQuality(9_849);
        uint256 fair = reward * 25 / 2;
        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(Staking.PriceBound.selector, fair * 9_849 / 10_000, fair * 9_850 / 10_000)
        );
        staking.claimEquity(address(nvda), reward, address(venue), _nvdaData(reward), 0);
    }

    function test_equity_partial_fill_reverts() public {
        MockVenue venue = _equityReady();
        vm.prank(alice);
        vm.expectRevert(Staking.PartialFill.selector);
        staking.claimEquity(address(nvda), reward, address(venue), _nvdaData(reward / 2), 0);
    }

    function test_equity_claim_during_a_live_stream() public {
        MockVenue venue = _equityReady();
        _taxEthToStaking(0.01 ether);
        vm.prank(carol);
        staking.notifyRewards();
        vm.warp(block.timestamp + 1 hours);
        uint256 part = staking.earned(alice);
        vm.warp(block.timestamp + 1);
        vm.prank(alice);
        uint256 got = staking.claimEquity(address(nvda), part, address(venue), _nvdaData(part), 0);
        assertEq(got, part * 25 / 2);
        assertEq(nvda.balanceOf(alice), got);
        assertGt(staking.earned(alice), 0);
    }

    function test_equity_amount_above_earned_reverts() public {
        MockVenue venue = _equityReady();
        vm.prank(alice);
        vm.expectRevert(Staking.AmountAboveEarned.selector);
        staking.claimEquity(address(nvda), reward + 1, address(venue), _nvdaData(reward + 1), 0);
    }

    function test_equity_zero_amount_reverts() public {
        MockVenue venue = _equityReady();
        vm.prank(alice);
        vm.expectRevert(Staking.NothingToClaim.selector);
        staking.claimEquity(address(nvda), 0, address(venue), _nvdaData(0), 0);
    }
}
