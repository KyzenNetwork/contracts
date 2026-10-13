// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {MockFeed} from "./MockFeed.sol";
import {MockStockToken} from "./MockStockToken.sol";

/// A swap target for Reserve and Staking tests. It fills at the feeds' price times
/// qualityBps / 10,000, computed exactly as the contracts compute their price bound.
contract MockVenue {
    IWETH public immutable weth;
    uint256 public qualityBps = 10_000;

    constructor(IWETH weth_) {
        weth = weth_;
    }

    receive() external payable {}

    function setQuality(uint256 bps) external {
        qualityBps = bps;
    }

    /// Pulls wethIn WETH from the caller and mints the asset to it.
    function buyAsset(MockStockToken asset, MockFeed assetFeed, MockFeed ethFeed, uint256 wethIn) external {
        require(IERC20(address(weth)).transferFrom(msg.sender, address(this), wethIn), "MockVenue: pull");
        uint256 out = Math.mulDiv(wethIn, _price(ethFeed), _price(assetFeed)) * qualityBps / 10_000;
        asset.mint(msg.sender, out);
    }

    /// Pulls amountIn of the asset from the caller and pays ETH, or WETH when asWeth.
    function sellAsset(MockStockToken asset, MockFeed assetFeed, MockFeed ethFeed, uint256 amountIn, bool asWeth)
        external
    {
        require(IERC20(address(asset)).transferFrom(msg.sender, address(this), amountIn), "MockVenue: pull");
        uint256 out = Math.mulDiv(amountIn, _price(assetFeed), _price(ethFeed)) * qualityBps / 10_000;
        if (asWeth) {
            weth.deposit{value: out}();
            require(IERC20(address(weth)).transfer(msg.sender, out), "MockVenue: pay");
        } else {
            (bool ok,) = msg.sender.call{value: out}("");
            require(ok, "MockVenue: ETH send");
        }
    }

    function _price(MockFeed feed) private view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        return uint256(answer) * 10 ** (18 - feed.decimals());
    }
}
