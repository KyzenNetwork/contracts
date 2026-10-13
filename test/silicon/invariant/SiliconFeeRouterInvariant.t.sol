// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../../../src/interfaces/IWETH.sol";
import {SiliconFeeRouter} from "../../../src/silicon/SiliconFeeRouter.sol";
import {MockWETH} from "../../mocks/MockWETH.sol";
import {MockToken, MockSwapTarget, EthSink} from "../mocks/SiliconMocks.sol";

/// Random ETH and WETH arrivals, conversions of fee synth, split changes and distributions.
/// The handler owns the router and is its keeper.
contract RouterHandler is Test {
    SiliconFeeRouter internal router;
    MockWETH internal weth;
    MockToken internal feeSynth;
    MockSwapTarget internal venue;

    /// ETH and WETH that reached the router: sent directly, or received from conversions.
    uint256 public ghostIn;
    uint256 public distributions;

    constructor(SiliconFeeRouter router_, MockWETH weth_, MockToken feeSynth_, MockSwapTarget venue_) {
        router = router_;
        weth = weth_;
        feeSynth = feeSynth_;
        venue = venue_;
    }

    function sendEth(uint256 amount) external {
        amount = bound(amount, 0, 100 ether);
        vm.deal(address(this), amount);
        (bool ok,) = address(router).call{value: amount}("");
        require(ok, "send");
        ghostIn += amount;
    }

    function sendWeth(uint256 amount) external {
        amount = bound(amount, 0, 100 ether);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        require(weth.transfer(address(router), amount), "weth");
        ghostIn += amount;
    }

    /// Fee synth arrives and the keeper converts it at a random rate, as WETH or ETH.
    function convert(uint256 amountIn, uint256 ethOut, bool asWeth) external {
        amountIn = bound(amountIn, 1, 1_000_000e18);
        ethOut = bound(ethOut, 0, 50 ether);
        feeSynth.mint(address(router), amountIn);
        vm.deal(address(venue), address(venue).balance + ethOut);
        bytes memory data = abi.encodeCall(MockSwapTarget.swap, (IERC20(address(feeSynth)), amountIn, ethOut, asWeth));
        uint256 received = router.convert(address(feeSynth), address(venue), data, amountIn, ethOut);
        ghostIn += received;
    }

    function setSplit(uint256 bps) external {
        router.setSplit(bound(bps, 0, 10_000));
    }

    function distribute() external {
        if (address(router).balance + weth.balanceOf(address(router)) == 0) return;
        router.distribute();
        ++distributions;
    }

    receive() external payable {}
}

/// The fee router never sends more ETH than it received, and what it holds plus what it sent is
/// exactly what it received.
contract SiliconFeeRouterInvariantTest is Test {
    SiliconFeeRouter internal router;
    MockWETH internal weth;
    EthSink internal reserveSink;
    EthSink internal stakingSink;
    RouterHandler internal handler;

    function setUp() public {
        weth = new MockWETH();
        router = new SiliconFeeRouter(IWETH(address(weth)));
        reserveSink = new EthSink();
        stakingSink = new EthSink();
        MockToken feeSynth = new MockToken("kH100", 18);
        MockSwapTarget venue = new MockSwapTarget(IWETH(address(weth)));
        router.setReserve(address(reserveSink));
        router.setStaking(address(stakingSink));
        router.setSplit(5_000);
        router.queueTarget(address(venue), true);
        vm.warp(block.timestamp + 24 hours);

        handler = new RouterHandler(router, weth, feeSynth, venue);
        router.setKeeper(address(handler));
        router.transferOwnership(address(handler));
        vm.prank(address(handler));
        router.acceptOwnership();
        targetContract(address(handler));
    }

    function invariant_never_sends_more_than_received() public view {
        assertLe(router.totalToReserve() + router.totalToStakers(), handler.ghostIn());
    }

    function invariant_eth_is_conserved() public view {
        assertEq(
            handler.ghostIn(),
            router.totalToReserve() + router.totalToStakers() + address(router).balance
                + weth.balanceOf(address(router))
        );
    }

    function invariant_recipients_received_their_totals() public view {
        assertEq(reserveSink.received(), router.totalToReserve());
        assertEq(stakingSink.received(), router.totalToStakers());
    }
}
