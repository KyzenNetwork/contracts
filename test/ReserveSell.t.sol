// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Reserve} from "../src/Reserve.sol";
import {PriceLib} from "../src/lib/PriceLib.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {Fixture} from "./utils/Fixture.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {HostileToken} from "./mocks/HostileToken.sol";
import {MalformedFeed} from "./mocks/MalformedFeed.sol";

contract TaxSwapTarget {
    function pullAndDump(IERC20 asset, uint256 amountIn, IERC20 kyzn, address pair, uint256 kyznAmount) external {
        asset.transferFrom(msg.sender, address(this), amountIn);
        kyzn.transfer(pair, kyznAmount);
    }
}

/// Sales only restore the 50% stage cap, from the first rotation on (SPEC 3.2).
contract ReserveSellTest is Fixture {
    uint256 internal constant WEDNESDAY_1400 = MONDAY_1400 + 2 days;
    MockVenue internal venue;

    function setUp() public override {
        super.setUp();
        venue = new MockVenue(IWETH(address(weth)));
        vm.deal(address(venue), 100 ether);
        reserve.queueTarget(address(venue), true);
        uint16[5] memory w = [uint16(4_000), 2_000, 2_000, 1_000, 1_000];
        registry.publish(w, keccak256("memo 1"), "https://kyzen.network/scheduler/memo-1", uint64(MONDAY_1400 + 1 days));
        vm.warp(WEDNESDAY_1400); // target live, first rotation executed
        _refreshFeeds();
    }

    function _sellNvda(uint256 amount, bool asWeth, uint256 minEthOut) internal returns (uint256) {
        vm.prank(keeper);
        return reserve.sell(
            address(nvda),
            address(venue),
            abi.encodeCall(MockVenue.sellAsset, (nvda, nvdaFeed, ethUsd, amount, asWeth)),
            amount,
            minEthOut
        );
    }

    function _expectSellRevert(uint256 amount, bytes memory reason) internal {
        vm.prank(keeper);
        vm.expectRevert(reason);
        reserve.sell(
            address(nvda),
            address(venue),
            abi.encodeCall(MockVenue.sellAsset, (nvda, nvdaFeed, ethUsd, amount, true)),
            amount,
            0
        );
    }

    function test_sell_above_the_cap() public {
        nvda.mint(address(reserve), 100e18); // design $20,000
        mu.mint(address(reserve), 20e18); // memory $2,000
        vm.expectEmit(address(reserve));
        emit Reserve.Sold(address(nvda), address(venue), 12.5e18, 1 ether);
        assertEq(_sellNvda(12.5e18, true, 0), 1 ether); // 12.5 NVDA = $2,500 = 1 ETH
        assertEq(address(reserve).balance, 1 ether);
        assertEq(nvda.allowance(address(reserve), address(venue)), 0);
    }

    function test_weth_proceeds_are_unwrapped() public {
        nvda.mint(address(reserve), 100e18);
        mu.mint(address(reserve), 20e18);
        assertEq(_sellNvda(12.5e18, true, 0), 1 ether);
        assertEq(weth.balanceOf(address(reserve)), 0);
        assertEq(address(reserve).balance, 1 ether);
    }

    function test_no_sales_before_the_first_rotation() public {
        vm.warp(MONDAY_1400 + 1 days - 1);
        _refreshFeeds();
        nvda.mint(address(reserve), 100e18);
        _expectSellRevert(1e18, abi.encodeWithSelector(Reserve.NoRotationYet.selector));
    }

    function test_sale_is_limited_to_the_excess() public {
        nvda.mint(address(reserve), 12e18); // design $2,400
        mu.mint(address(reserve), 20e18); // memory $2,000: design 54.5%, excess $200 = 1 NVDA
        _expectSellRevert(1e18 + 1, abi.encodeWithSelector(Reserve.NotAboveCap.selector));
        assertEq(_sellNvda(1e18, true, 0), 0.08 ether);
    }

    function test_no_sale_at_or_below_the_cap() public {
        nvda.mint(address(reserve), 10e18); // $2,000
        mu.mint(address(reserve), 20e18); // $2,000: exactly 50%
        _expectSellRevert(1e18, abi.encodeWithSelector(Reserve.NotAboveCap.selector));
    }

    /// Test gap closed (fix round item 2): a stale price is not an unreadable one. It still
    /// counts at its last published value in the cap check, so design must still revert at
    /// exactly 50% even though memory's feed has not answered in 3 days. If stale holdings
    /// were instead left out of the cap check, design would look like all of Reserve value and
    /// this sale would wrongly pass.
    function test_a_stale_price_still_counts_in_the_cap_check() public {
        nvda.mint(address(reserve), 10e18); // design $2,000
        mu.mint(address(reserve), 20e18); // memory $2,000 at its last published price: exactly 50%
        muFeed.set(100e8, block.timestamp - 3 days); // last published over a weekend ago
        _expectSellRevert(1e18, abi.encodeWithSelector(Reserve.NotAboveCap.selector));
    }

    function test_eth_counts_in_the_total() public {
        nvda.mint(address(reserve), 12e18); // $2,400
        vm.deal(address(reserve), 1 ether); // $2,500: design 49%
        _expectSellRevert(1e18, abi.encodeWithSelector(Reserve.NotAboveCap.selector));
    }

    function test_sale_slice_is_at_most_1_eth_of_value() public {
        nvda.mint(address(reserve), 100e18);
        mu.mint(address(reserve), 20e18);
        _expectSellRevert(12.5e18 + 1e10, abi.encodeWithSelector(Reserve.BadAmount.selector));
        _expectSellRevert(0, abi.encodeWithSelector(Reserve.BadAmount.selector));
    }

    function test_sale_price_bound() public {
        nvda.mint(address(reserve), 100e18);
        mu.mint(address(reserve), 20e18);
        venue.setQuality(9_849);
        _expectSellRevert(12.5e18, abi.encodeWithSelector(Reserve.PriceBound.selector, 0.9849 ether, 0.985 ether));
        venue.setQuality(9_850);
        assertEq(_sellNvda(12.5e18, true, 0), 0.985 ether);
    }

    function test_sales_respect_spacing_and_window() public {
        nvda.mint(address(reserve), 100e18);
        mu.mint(address(reserve), 20e18);
        _sellNvda(1e18, true, 0);
        _expectSellRevert(1e18, abi.encodeWithSelector(Reserve.TooSoon.selector));
        vm.warp(WEDNESDAY_1400 + 3 days); // Saturday
        _refreshFeeds();
        _expectSellRevert(1e18, abi.encodeWithSelector(Reserve.OutsideWindow.selector));
    }

    function test_stale_feed_on_another_asset_does_not_block_a_cap_sale() public {
        nvda.mint(address(reserve), 100e18); // design $20,000
        mu.mint(address(reserve), 20e18); // memory $2,000
        muFeed.set(100e8, block.timestamp - 3 days); // last published over a weekend ago
        assertEq(_sellNvda(12.5e18, true, 0), 1 ether);
    }

    function test_a_broken_feed_on_another_asset_does_not_block_a_cap_sale() public {
        nvda.mint(address(reserve), 100e18); // design $20,000
        mu.mint(address(reserve), 20e18); // memory $2,000, left out while its answer is 0
        muFeed.set(0, block.timestamp);
        assertEq(_sellNvda(12.5e18, true, 0), 1 ether);
    }

    function test_an_unreadable_asset_does_not_block_a_cap_sale() public {
        HostileToken hostile = new HostileToken();
        _listNow(address(hostile), address(new MockFeed(8, 100e8)), 1);
        hostile.mint(address(reserve), 20e18); // memory $2,000
        hostile.setBalanceMode(HostileToken.Mode.Revert);
        nvda.mint(address(reserve), 100e18); // design $20,000
        assertEq(_sellNvda(12.5e18, true, 0), 1 ether);
    }

    /// Fix round item 1: a feed that answers with too few bytes, with nothing, or that burns
    /// all its gas does not block a cap sale of another stage either; the holding priced by it
    /// is simply left out, the same as today's reverting-feed case.
    function test_a_malformed_feed_on_another_asset_does_not_block_a_cap_sale() public {
        MalformedFeed bad = new MalformedFeed(8, 100e8);
        MockStockToken other = new MockStockToken("OTHER");
        _listNow(address(other), address(bad), 1); // memory
        other.mint(address(reserve), 20e18); // memory $2,000
        nvda.mint(address(reserve), 100e18); // design $20,000

        MalformedFeed.Mode[3] memory modes =
            [MalformedFeed.Mode.ShortAnswer, MalformedFeed.Mode.AnswerNothing, MalformedFeed.Mode.BurnGas];
        for (uint256 i; i < modes.length; ++i) {
            bad.setMode(modes[i]);
            assertEq(_sellNvda(12.5e18, true, 0), 1 ether);
            vm.warp(block.timestamp + 15 minutes); // clears NVDA's per-asset trade spacing
            _refreshFeeds();
        }
    }

    function test_the_traded_asset_and_eth_feeds_must_be_fresh_for_a_sale() public {
        nvda.mint(address(reserve), 100e18);
        mu.mint(address(reserve), 20e18);
        nvdaFeed.set(200e8, block.timestamp - 24 hours - 1);
        _expectSellRevert(12.5e18, abi.encodeWithSelector(PriceLib.StalePrice.selector, address(nvdaFeed)));
        _refreshFeeds();
        ethUsd.set(2_500e8, block.timestamp - 24 hours - 1);
        _expectSellRevert(12.5e18, abi.encodeWithSelector(PriceLib.StalePrice.selector, address(ethUsd)));
        _refreshFeeds();
        nvda.setOraclePaused(true);
        _expectSellRevert(12.5e18, abi.encodeWithSelector(Reserve.FeedPaused.selector, address(nvda)));
    }

    function test_pending_asset_cannot_be_sold() public {
        MockStockToken tsm = new MockStockToken("TSM");
        MockFeed tsmFeed = new MockFeed(8, 180e8);
        reserve.addAsset(address(tsm), address(tsmFeed), 2); // pending for 24 hours
        tsm.mint(address(reserve), 100e18); // fab $18,000, all of Reserve value
        vm.prank(keeper);
        vm.expectRevert(Reserve.NotListed.selector);
        reserve.sell(
            address(tsm),
            address(venue),
            abi.encodeCall(MockVenue.sellAsset, (tsm, tsmFeed, ethUsd, 10e18, true)),
            10e18,
            0
        );
    }

    function test_only_the_keeper_sells() public {
        nvda.mint(address(reserve), 100e18);
        vm.expectRevert(Reserve.NotKeeper.selector);
        reserve.sell(address(nvda), address(venue), "", 1e18, 0);
    }

    function test_native_eth_is_not_counted_as_proceeds() public {
        nvda.mint(address(reserve), 100e18);
        mu.mint(address(reserve), 20e18);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Reserve.PriceBound.selector, 0, 0.985 ether));
        reserve.sell(
            address(nvda),
            address(venue),
            abi.encodeCall(MockVenue.sellAsset, (nvda, nvdaFeed, ethUsd, 12.5e18, false)),
            12.5e18,
            0
        );
    }

    function test_tax_eth_arriving_during_a_sale_is_not_proceeds() public {
        TaxSwapTarget target = new TaxSwapTarget();
        reserve.queueTarget(address(target), true);
        vm.warp(MONDAY_1400 + 3 days); // 24 hours after queueing
        _launch();
        _buy(alice, 0.05 ether);
        token.transfer(address(target), 1_000_000e18);
        nvda.mint(address(reserve), 100e18);
        mu.mint(address(reserve), 20e18);
        _refreshFeeds();
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Reserve.PriceBound.selector, 0, 7.88e14));
        reserve.sell(
            address(nvda),
            address(target),
            abi.encodeCall(
                TaxSwapTarget.pullAndDump, (IERC20(address(nvda)), 0.01e18, IERC20(address(token)), pair, 1_000_000e18)
            ),
            0.01e18,
            0
        );
    }

    function test_sale_cannot_touch_claimed_tokens() public {
        token.transfer(alice, 10_000_000e18);
        _launch();
        nvda.mint(address(reserve), 100e18);
        amd.mint(address(reserve), 10e18);
        mu.mint(address(reserve), 20e18);
        amd.setPaused(true);
        vm.startPrank(alice);
        token.approve(address(reserve), 10_000_000e18);
        reserve.redeem(10_000_000e18);
        vm.stopPrank();
        amd.setPaused(false);
        vm.prank(keeper);
        vm.expectRevert(Reserve.BadAmount.selector);
        reserve.sell(
            address(amd),
            address(venue),
            abi.encodeCall(MockVenue.sellAsset, (amd, amdFeed, ethUsd, 10e18, true)),
            10e18,
            0
        );
        vm.prank(keeper);
        assertEq(
            reserve.sell(
                address(amd),
                address(venue),
                abi.encodeCall(MockVenue.sellAsset, (amd, amdFeed, ethUsd, 10e18 - 0.098e18, true)),
                10e18 - 0.098e18,
                0
            ),
            0.59412 ether
        );
    }
}
