// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Reserve} from "../src/Reserve.sol";
import {PriceLib} from "../src/lib/PriceLib.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {Fixture} from "./utils/Fixture.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {HostileToken} from "./mocks/HostileToken.sol";

/// A swap target that sends the WETH it may pull to a beneficiary and mints dust of the asset.
contract DrainVenue {
    address public immutable beneficiary;

    constructor(address beneficiary_) {
        beneficiary = beneficiary_;
    }

    function take(IERC20 weth, MockStockToken asset, uint256 wethIn, uint256 assetOut) external {
        require(weth.transferFrom(msg.sender, beneficiary, wethIn), "DrainVenue: pull");
        asset.mint(msg.sender, assetOut);
    }
}

/// Keeper purchases under the buy discipline (SPEC 3.2).
contract ReserveBuyTest is Fixture {
    uint256 internal constant WEDNESDAY_1400 = MONDAY_1400 + 2 days;
    MockVenue internal venue;

    function setUp() public override {
        super.setUp();
        venue = new MockVenue(IWETH(address(weth)));
        reserve.queueTarget(address(venue), true);
        vm.warp(WEDNESDAY_1400); // the target has been live since Tuesday 14:00
        _refreshFeeds();
        vm.deal(address(reserve), 10 ether);
    }

    function _nvdaData(uint256 wethIn) internal view returns (bytes memory) {
        return abi.encodeCall(MockVenue.buyAsset, (nvda, nvdaFeed, ethUsd, wethIn));
    }

    function _buyNvda(uint256 wethIn, uint256 ethIn, uint256 minOut) internal returns (uint256) {
        vm.prank(keeper);
        return reserve.buy(address(nvda), address(venue), _nvdaData(wethIn), ethIn, minOut);
    }

    function _expectBuyRevert(bytes memory reason) internal {
        vm.prank(keeper);
        vm.expectRevert(reason);
        reserve.buy(address(nvda), address(venue), _nvdaData(0.1 ether), 0.1 ether, 0);
    }

    function test_buy_within_the_bounds() public {
        vm.expectEmit(address(reserve));
        emit Reserve.Bought(address(nvda), address(venue), 1 ether, 12.5e18);
        uint256 got = _buyNvda(1 ether, 1 ether, 0);
        assertEq(got, 12.5e18); // 1 ETH x $2,500 / $200
        assertEq(nvda.balanceOf(address(reserve)), 12.5e18);
        assertEq(address(reserve).balance, 9 ether);
        assertEq(weth.balanceOf(address(reserve)), 0);
        assertEq(weth.allowance(address(reserve), address(venue)), 0);
        (,,, uint64 lastTradeAt,) = reserve.assetInfo(address(nvda));
        assertEq(lastTradeAt, block.timestamp);
    }

    function test_only_the_keeper_buys() public {
        vm.expectRevert(Reserve.NotKeeper.selector);
        reserve.buy(address(nvda), address(venue), _nvdaData(0.1 ether), 0.1 ether, 0);
    }

    function test_asset_must_be_listed() public {
        MockStockToken other = new MockStockToken("OTHER");
        vm.prank(keeper);
        vm.expectRevert(Reserve.NotListed.selector);
        reserve.buy(address(other), address(venue), _nvdaData(0.1 ether), 0.1 ether, 0);
    }

    function test_target_must_be_live() public {
        MockVenue fresh = new MockVenue(IWETH(address(weth)));
        reserve.queueTarget(address(fresh), true);
        vm.prank(keeper);
        vm.expectRevert(Reserve.BadTarget.selector);
        reserve.buy(address(nvda), address(fresh), _nvdaData(0.1 ether), 0.1 ether, 0);
    }

    function test_market_hours_only() public {
        uint256 wednesday = WEDNESDAY_1400 - 14 hours; // 00:00 UTC
        uint256[4] memory closed = [
            wednesday + 13 hours + 29 minutes + 59, // before 13:30
            wednesday + 21 hours, // 21:00 closes the window
            wednesday + 3 days + 14 hours, // Saturday
            wednesday + 4 days + 14 hours // Sunday
        ];
        for (uint256 i; i < closed.length; ++i) {
            vm.warp(closed[i]);
            _refreshFeeds();
            _expectBuyRevert(abi.encodeWithSelector(Reserve.OutsideWindow.selector));
        }
        vm.warp(wednesday + 13 hours + 30 minutes);
        _refreshFeeds();
        _buyNvda(0.1 ether, 0.1 ether, 0);
        vm.warp(wednesday + 2 days + 20 hours + 59 minutes + 59); // Friday 20:59:59
        _refreshFeeds();
        _buyNvda(0.1 ether, 0.1 ether, 0);
    }

    function test_15_minutes_between_purchases_of_an_asset() public {
        _buyNvda(0.1 ether, 0.1 ether, 0);
        vm.warp(block.timestamp + 15 minutes - 1);
        _expectBuyRevert(abi.encodeWithSelector(Reserve.TooSoon.selector));
        vm.warp(block.timestamp + 1);
        _buyNvda(0.1 ether, 0.1 ether, 0);
        // spacing is per asset
        vm.prank(keeper);
        reserve.buy(
            address(amd),
            address(venue),
            abi.encodeCall(MockVenue.buyAsset, (amd, amdFeed, ethUsd, 0.1 ether)),
            0.1 ether,
            0
        );
    }

    function test_slice_is_at_most_1_eth() public {
        vm.prank(keeper);
        vm.expectRevert(Reserve.BadAmount.selector);
        reserve.buy(address(nvda), address(venue), _nvdaData(1 ether + 1), 1 ether + 1, 0);
        vm.prank(keeper);
        vm.expectRevert(Reserve.BadAmount.selector);
        reserve.buy(address(nvda), address(venue), _nvdaData(0), 0, 0);
    }

    function test_asset_feed_must_be_fresh() public {
        nvdaFeed.set(200e8, block.timestamp - 24 hours);
        _buyNvda(0.1 ether, 0.1 ether, 0); // exactly 24 hours old is fresh
        vm.warp(block.timestamp + 15 minutes);
        _expectBuyRevert(abi.encodeWithSelector(PriceLib.StalePrice.selector, address(nvdaFeed)));
    }

    function test_eth_feed_must_be_fresh() public {
        ethUsd.set(2_500e8, block.timestamp - 24 hours - 1);
        _expectBuyRevert(abi.encodeWithSelector(PriceLib.StalePrice.selector, address(ethUsd)));
    }

    function test_no_buy_while_the_oracle_is_paused() public {
        nvda.setOraclePaused(true);
        _expectBuyRevert(abi.encodeWithSelector(Reserve.FeedPaused.selector, address(nvda)));
    }

    function test_price_bound_is_98_5_percent() public {
        venue.setQuality(9_850);
        assertEq(_buyNvda(1 ether, 1 ether, 0), 12.3125e18); // exactly at the bound
        vm.warp(block.timestamp + 15 minutes);
        venue.setQuality(9_849);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Reserve.PriceBound.selector, 12.31125e18, 12.3125e18));
        reserve.buy(address(nvda), address(venue), _nvdaData(1 ether), 1 ether, 0);
    }

    function test_keeper_minimum_applies() public {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Reserve.PriceBound.selector, 12.5e18, 12.5e18 + 1));
        reserve.buy(address(nvda), address(venue), _nvdaData(1 ether), 1 ether, 12.5e18 + 1);
    }

    function test_unspent_weth_returns_as_eth() public {
        uint256 got = _buyNvda(0.4 ether, 1 ether, 0); // the venue pulls only 0.4
        assertEq(got, 5e18);
        assertEq(address(reserve).balance, 10 ether - 0.4 ether);
        assertEq(weth.balanceOf(address(reserve)), 0);
    }

    function test_target_that_pulls_nothing_reverts() public {
        vm.prank(keeper);
        vm.expectRevert(Reserve.BadAmount.selector);
        reserve.buy(address(nvda), address(venue), _nvdaData(0), 0.1 ether, 0);
    }

    /// Fix round item 3: the buy path's before/after balance reads of the asset now use the
    /// same BALANCE_GAS cap as redemption, so the keeper cannot keep buying into a holding that
    /// redemption would silently skip because it cannot read the asset's balance.
    function test_unreadable_asset_cannot_be_bought() public {
        HostileToken hostile = new HostileToken();
        MockFeed hostileFeed = new MockFeed(8, 100e8);
        _listNow(address(hostile), address(hostileFeed), 2);
        bytes memory data =
            abi.encodeCall(MockVenue.buyAsset, (MockStockToken(address(hostile)), hostileFeed, ethUsd, 0.1 ether));

        HostileToken.Mode[3] memory modes =
            [HostileToken.Mode.Revert, HostileToken.Mode.BurnGas, HostileToken.Mode.ShortAnswer];
        for (uint256 i; i < modes.length; ++i) {
            hostile.setBalanceMode(modes[i]);
            vm.prank(keeper);
            vm.expectRevert(abi.encodeWithSelector(Reserve.UnreadableAsset.selector, address(hostile)));
            reserve.buy(address(hostile), address(venue), data, 0.1 ether, 0);
        }

        hostile.setBalanceMode(HostileToken.Mode.Normal);
        vm.prank(keeper);
        uint256 got = reserve.buy(address(hostile), address(venue), data, 0.1 ether, 0);
        assertGt(got, 0);
        assertEq(hostile.balanceOf(address(reserve)), got);
    }

    /// Final review item 2: the owner can list any 18-decimal token with a feed it chose, so the
    /// price bound alone cannot stop a fake asset. Every listing after deployment waits 24 hours in
    /// public and takes effect only through listAsset, and the keeper cannot buy the asset before.
    function test_fake_asset_cannot_be_bought_within_24_hours() public {
        address attacker = makeAddr("attacker");
        DrainVenue drain = new DrainVenue(attacker);
        reserve.queueTarget(address(drain), true); // innocuous-looking, a day ahead
        vm.warp(WEDNESDAY_1400 + 1 days); // Thursday 14:00 UTC: the drain target is live

        MockStockToken fake = new MockStockToken("FAKE");
        // $2.5 trillion a token, so 1 ETH ($2,500) prices at 1e9 wei of it.
        MockFeed fakeFeed = new MockFeed(8, 2_500_000_000_000e8);
        reserve.addAsset(address(fake), address(fakeFeed), 3);
        bytes memory data = abi.encodeCall(DrainVenue.take, (IERC20(address(weth)), fake, 1 ether, 1e9));

        uint256[4] memory attempts = [
            WEDNESDAY_1400 + 1 days, // queued this second
            WEDNESDAY_1400 + 1 days + 3 hours,
            WEDNESDAY_1400 + 1 days + 6 hours + 59 minutes, // Thursday 20:59 UTC
            WEDNESDAY_1400 + 2 days // Friday 14:00 UTC: due, but listed only by listAsset
        ];
        for (uint256 i; i < attempts.length; ++i) {
            vm.warp(attempts[i]);
            _refreshFeeds();
            fakeFeed.set(2_500_000_000_000e8, block.timestamp);
            vm.prank(keeper);
            vm.expectRevert(Reserve.NotListed.selector);
            reserve.buy(address(fake), address(drain), data, 1 ether, 0);
        }
        assertEq(address(reserve).balance, 10 ether);
        assertEq(weth.balanceOf(attacker), 0);
        assertEq(fake.balanceOf(address(reserve)), 0);
    }
}
