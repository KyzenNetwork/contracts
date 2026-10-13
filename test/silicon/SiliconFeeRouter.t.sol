// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {SiliconFeeRouter} from "../../src/silicon/SiliconFeeRouter.sol";
import {Fixture} from "../utils/Fixture.sol";
import {MockToken, MockSwapTarget} from "./mocks/SiliconMocks.sol";

/// The Silicon fee router (SPEC 3.5): revenue in, ETH out to the Reserve and to stakers, on the
/// real Gen 1 Reserve and Staking (Staking takes ETH only from the token and its fee source).
contract SiliconFeeRouterTest is Fixture {
    SiliconFeeRouter internal router_;
    MockSwapTarget internal venue;
    MockToken internal feeSynth;
    address internal routerKeeper = makeAddr("routerKeeper");

    function setUp() public override {
        super.setUp();
        router_ = new SiliconFeeRouter(IWETH(address(weth)));
        venue = new MockSwapTarget(IWETH(address(weth)));
        vm.deal(address(venue), 1_000 ether);
        feeSynth = new MockToken("kH100", 18);
        feeSynth.mint(address(router_), 1_000e18);
    }

    /// Recipients, split 60% Reserve / 40% stakers (a test level), Staking naming the router.
    function _configure() internal {
        router_.setReserve(address(reserve));
        router_.setStaking(address(staking));
        router_.setSplit(6_000);
        staking.setFeeSource(address(router_));
        router_.setKeeper(routerKeeper);
    }

    function _allowVenue() internal {
        router_.queueTarget(address(venue), true);
        vm.warp(block.timestamp + 24 hours);
    }

    function _convertCall(uint256 amountIn, uint256 ethOut, bool asWeth) internal view returns (bytes memory) {
        return abi.encodeCall(MockSwapTarget.swap, (IERC20(address(feeSynth)), amountIn, ethOut, asWeth));
    }

    // ================================================================ owner

    function test_constructor() public {
        assertEq(address(router_.weth()), address(weth));
        assertEq(router_.owner(), address(this));
        assertFalse(router_.splitSet());
        vm.expectRevert(SiliconFeeRouter.ZeroAddress.selector);
        new SiliconFeeRouter(IWETH(address(0)));
    }

    function test_owner_settings() public {
        vm.startPrank(alice);
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(notOwner);
        router_.setKeeper(alice);
        vm.expectRevert(notOwner);
        router_.setReserve(alice);
        vm.expectRevert(notOwner);
        router_.setStaking(alice);
        vm.expectRevert(notOwner);
        router_.setSplit(1);
        vm.expectRevert(notOwner);
        router_.queueTarget(address(venue), true);
        vm.stopPrank();

        vm.expectRevert(SiliconFeeRouter.ZeroAddress.selector);
        router_.setReserve(address(0));
        vm.expectRevert(SiliconFeeRouter.ZeroAddress.selector);
        router_.setStaking(address(0));
        vm.expectRevert(abi.encodeWithSelector(SiliconFeeRouter.BpsAboveMaximum.selector, 10_001, 10_000));
        router_.setSplit(10_001);

        vm.expectEmit(address(router_));
        emit SiliconFeeRouter.KeeperSet(routerKeeper);
        router_.setKeeper(routerKeeper);
        vm.expectEmit(address(router_));
        emit SiliconFeeRouter.ReserveSet(address(reserve));
        router_.setReserve(address(reserve));
        vm.expectEmit(address(router_));
        emit SiliconFeeRouter.StakingSet(address(staking));
        router_.setStaking(address(staking));
        vm.expectEmit(address(router_));
        emit SiliconFeeRouter.SplitSet(0);
        router_.setSplit(0); // zero is a split like any other
        assertTrue(router_.splitSet());
        assertEq(router_.keeper(), routerKeeper);
        assertEq(router_.reserve(), address(reserve));
        assertEq(router_.staking(), address(staking));
    }

    // ================================================================ distribution

    function test_distribute_needs_its_settings() public {
        vm.deal(address(router_), 1 ether);
        vm.expectRevert(SiliconFeeRouter.SplitUnset.selector);
        router_.distribute();
        router_.setSplit(5_000);
        vm.expectRevert(SiliconFeeRouter.RecipientsUnset.selector);
        router_.distribute();
        router_.setReserve(address(reserve));
        vm.expectRevert(SiliconFeeRouter.RecipientsUnset.selector);
        router_.distribute();
        router_.setStaking(address(staking));
        staking.setFeeSource(address(router_));
        router_.distribute();
        vm.expectRevert(SiliconFeeRouter.NothingToDistribute.selector);
        router_.distribute();
    }

    /// 1 ETH and 0.5 WETH, split 60/40: 0.9 ETH to the Reserve, 0.6 ETH to Staking.
    function test_distribute_splits_eth_and_unwraps_weth() public {
        _configure();
        vm.deal(address(router_), 1 ether);
        weth.deposit{value: 0.5 ether}();
        assertTrue(weth.transfer(address(router_), 0.5 ether));
        uint256 reserveBefore = address(reserve).balance;
        uint256 stakingBefore = address(staking).balance;

        vm.expectEmit(address(router_));
        emit SiliconFeeRouter.Distributed(0.9 ether, 0.6 ether);
        vm.prank(carol); // anyone
        (uint256 toReserve, uint256 toStakers) = router_.distribute();
        assertEq(toReserve, 0.9 ether);
        assertEq(toStakers, 0.6 ether);
        assertEq(address(reserve).balance - reserveBefore, 0.9 ether);
        assertEq(address(staking).balance - stakingBefore, 0.6 ether);
        assertEq(address(router_).balance, 0);
        assertEq(weth.balanceOf(address(router_)), 0);
        assertEq(router_.totalToReserve(), 0.9 ether);
        assertEq(router_.totalToStakers(), 0.6 ether);

        // The stakers' share streams like the 1% tax share once notifyRewards runs.
        staking.notifyRewards();
        assertEq(staking.lastFundingAmount(), uint256(0.6 ether) / 86_400 * 86_400); // whole wei per second
    }

    /// Staking refuses ETH from anyone but the token and its fee source.
    function test_staking_must_name_the_router() public {
        _configure();
        staking.setFeeSource(address(0));
        vm.deal(address(router_), 1 ether);
        vm.expectRevert(SiliconFeeRouter.EthSendFailed.selector);
        router_.distribute();
        staking.setFeeSource(address(router_));
        router_.distribute();
    }

    function test_split_edges_and_rounding() public {
        _configure();
        router_.setSplit(10_000);
        vm.deal(address(router_), 1 ether);
        (uint256 toReserve, uint256 toStakers) = router_.distribute();
        assertEq(toReserve, 1 ether);
        assertEq(toStakers, 0);

        router_.setSplit(0);
        vm.deal(address(router_), 1 ether);
        (toReserve, toStakers) = router_.distribute();
        assertEq(toReserve, 0);
        assertEq(toStakers, 1 ether);

        router_.setSplit(3_333);
        vm.deal(address(router_), 7);
        (toReserve, toStakers) = router_.distribute();
        assertEq(toReserve, 2);
        assertEq(toStakers, 5, "the stakers receive the rounding");
    }

    // ================================================================ swap targets

    function test_target_rule_and_delay() public {
        _configure();
        address[5] memory forbidden = [address(0), address(router_), address(weth), address(reserve), address(staking)];
        for (uint256 i; i < forbidden.length; ++i) {
            vm.expectRevert(SiliconFeeRouter.BadTarget.selector);
            router_.queueTarget(forbidden[i], true);
            assertFalse(router_.isTargetAllowed(forbidden[i]));
        }

        vm.expectEmit(address(router_));
        emit SiliconFeeRouter.TargetQueued(address(venue), true, block.timestamp + 24 hours);
        router_.queueTarget(address(venue), true);
        (bool allowed, uint256 effectiveAt) = router_.pendingTarget(address(venue));
        assertTrue(allowed);
        assertEq(effectiveAt, block.timestamp + 24 hours);
        assertFalse(router_.isTargetAllowed(address(venue)));
        vm.warp(block.timestamp + 24 hours - 1);
        assertFalse(router_.isTargetAllowed(address(venue)));
        vm.warp(block.timestamp + 1);
        assertTrue(router_.isTargetAllowed(address(venue)));
        (, effectiveAt) = router_.pendingTarget(address(venue));
        assertEq(effectiveAt, 0);

        // Removal waits 24 hours too.
        router_.queueTarget(address(venue), false);
        assertTrue(router_.isTargetAllowed(address(venue)));
        vm.warp(block.timestamp + 24 hours);
        assertFalse(router_.isTargetAllowed(address(venue)));
    }

    /// A target that later becomes the Reserve or Staking is never callable.
    function test_target_that_becomes_a_recipient_is_forbidden() public {
        _configure();
        _allowVenue();
        assertTrue(router_.isTargetAllowed(address(venue)));
        router_.setReserve(address(venue));
        assertFalse(router_.isTargetAllowed(address(venue)));
    }

    // ================================================================ conversion

    function test_convert_to_weth() public {
        _configure();
        _allowVenue();
        vm.expectEmit(address(router_));
        emit SiliconFeeRouter.Converted(address(feeSynth), address(venue), 100e18, 0.08 ether);
        vm.prank(routerKeeper);
        uint256 received = router_.convert(
            address(feeSynth), address(venue), _convertCall(100e18, 0.08 ether, true), 100e18, 0.08 ether
        );
        assertEq(received, 0.08 ether);
        assertEq(weth.balanceOf(address(router_)), 0.08 ether);
        assertEq(feeSynth.balanceOf(address(router_)), 900e18);
        assertEq(feeSynth.allowance(address(router_), address(venue)), 0, "approval reset");
    }

    function test_convert_to_eth() public {
        _configure();
        _allowVenue();
        vm.prank(routerKeeper);
        uint256 received =
            router_.convert(address(feeSynth), address(venue), _convertCall(10e18, 0.01 ether, false), 10e18, 0);
        assertEq(received, 0.01 ether);
        assertEq(address(router_).balance, 0.01 ether);
    }

    function test_convert_rules() public {
        _configure();
        bytes memory data = _convertCall(10e18, 0.01 ether, true);
        vm.prank(alice);
        vm.expectRevert(SiliconFeeRouter.NotKeeper.selector);
        router_.convert(address(feeSynth), address(venue), data, 10e18, 0);

        vm.startPrank(routerKeeper);
        vm.expectRevert(SiliconFeeRouter.ZeroAmount.selector);
        router_.convert(address(feeSynth), address(venue), data, 0, 0);
        vm.expectRevert(SiliconFeeRouter.BadToken.selector);
        router_.convert(address(weth), address(venue), data, 10e18, 0);
        vm.expectRevert(SiliconFeeRouter.BadToken.selector);
        router_.convert(address(0), address(venue), data, 10e18, 0);
        vm.expectRevert(SiliconFeeRouter.BadTarget.selector);
        router_.convert(address(feeSynth), address(venue), data, 10e18, 0); // not yet allowed
        vm.stopPrank();

        _allowVenue();
        vm.startPrank(routerKeeper);
        vm.expectRevert(SiliconFeeRouter.BadTarget.selector);
        router_.convert(address(venue), address(venue), data, 10e18, 0); // the target as the token
        vm.expectRevert(abi.encodeWithSelector(SiliconFeeRouter.InsufficientOutput.selector, 0.01 ether, 0.02 ether));
        router_.convert(address(feeSynth), address(venue), data, 10e18, 0.02 ether);
        vm.stopPrank();
    }

    /// The target can pull no more than amountIn: a call asking for more fails in the token.
    function test_convert_caps_what_the_target_takes() public {
        _configure();
        _allowVenue();
        vm.prank(routerKeeper);
        vm.expectRevert();
        router_.convert(address(feeSynth), address(venue), _convertCall(11e18, 0.01 ether, true), 10e18, 0);
    }

    /// Fee synth to WETH, then out as ETH to the Reserve and stakers.
    function test_convert_then_distribute() public {
        _configure();
        _allowVenue();
        vm.prank(routerKeeper);
        router_.convert(address(feeSynth), address(venue), _convertCall(500e18, 0.4 ether, true), 500e18, 0.4 ether);
        (uint256 toReserve, uint256 toStakers) = router_.distribute();
        assertEq(toReserve + toStakers, 0.4 ether);
        assertEq(toReserve, 0.24 ether);
    }

    function test_ownership_moves_in_two_steps() public {
        router_.transferOwnership(alice);
        vm.prank(alice);
        router_.acceptOwnership();
        assertEq(router_.owner(), alice);
    }
}
