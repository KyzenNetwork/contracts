// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {Reserve} from "../src/Reserve.sol";
import {Staking} from "../src/Staking.sol";
import {GatewaySettlement} from "../src/GatewaySettlement.sol";
import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {KyzenProtocol, KyzenMainnetProtocol, NotRobinhoodToken, WrongChain} from "../script/KyzenProtocol.sol";
import {RobinhoodChain} from "../script/RobinhoodChain.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";

/// Step two of the mainnet launch (script/KyzenProtocol.sol) offline. As on Robinhood Chain, the
/// owner first deploys the $KYZN token alone from its wallet (the development wallet is that same
/// wallet), on the official Uniswap v2 factory and Router02 (the unmodified build in
/// external/uniswap-v2) with a stand-in WETH. Then the owner deploys KyzenProtocol, which builds the
/// weight registry, the Reserve (seven stand-in stock tokens at RobinhoodChain's stages), Staking
/// and the Gateway; the owner sets the three in the token and accepts ownership of the four.
/// test/KyzenLiquidity.t.sol covers step three.
contract KyzenProtocolTest is Test {
    /// Thursday 1 October 2026, 12:00 UTC: the deployment, in these tests.
    uint256 internal constant DEPLOYED_AT = 1_790_856_000;
    address internal constant SWAP_TARGET = address(0x5a9);
    /// The server's wallets for step two (SPEC 3.1).
    address internal constant MAINNET_KEEPER = 0x9773407713fe52BfF54C5E3f519A5EA4F7334538;
    address internal constant MAINNET_OPERATOR = 0x2Ba4C980AaCcd4896d8418960D26400259C839Bb;

    MockWETH internal weth;
    address internal factory;
    IUniswapV2Router02 internal router;
    address internal ethUsd;
    RobinhoodChain.Asset[] internal assetList;
    KyznToken internal token;

    address internal owner = makeAddr("owner");
    address internal host = makeAddr("host");
    address internal keeper = makeAddr("keeper");
    address internal operator = makeAddr("operator");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(DEPLOYED_AT);
        weth = new MockWETH();
        factory = deployCode("external/uniswap-v2/UniswapV2Factory.json", abi.encode(address(this)));
        router = IUniswapV2Router02(
            deployCode("external/uniswap-v2/UniswapV2Router02.json", abi.encode(factory, address(weth)))
        );
        ethUsd = address(new MockFeed(8, 2_500e8));
        RobinhoodChain.Asset[7] memory mainnet = RobinhoodChain.assets();
        string[7] memory symbols = ["NVDA", "AMD", "MU", "SNDK", "TSM", "INTC", "ASML"];
        for (uint256 i; i < mainnet.length; ++i) {
            assetList.push(
                RobinhoodChain.Asset({
                    token: address(new MockStockToken(symbols[i])),
                    feed: address(new MockFeed(8, 100e8)),
                    stage: mainnet[i].stage
                })
            );
        }
        // Step one, as on mainnet: the owner deploys the token alone, its own development wallet.
        vm.prank(owner);
        token = new KyznToken(router, owner);
    }

    function _setup() internal view returns (KyzenProtocol.Setup memory s) {
        s.token = token;
        s.ethUsdFeed = ethUsd;
        s.assets = assetList;
        s.equityAssetA = assetList[0].token;
        s.equityAssetB = assetList[1].token;
        s.swapTarget = SWAP_TARGET;
        s.hostPayout = host;
        s.keeper = keeper;
        s.operator = operator;
    }

    function _deploy(KyzenProtocol.Setup memory s) internal returns (KyzenProtocol p) {
        vm.prank(owner);
        p = new KyzenProtocol(s);
    }

    function _four(KyzenProtocol p) internal view returns (Ownable2Step[4] memory four) {
        four = [
            Ownable2Step(address(p.registry())),
            Ownable2Step(address(p.reserve())),
            Ownable2Step(address(p.staking())),
            Ownable2Step(address(p.gateway()))
        ];
    }

    /// What the owner does next: sets the three in the token and accepts the four.
    function _takeOver(KyznToken t, KyzenProtocol p) internal {
        vm.startPrank(owner);
        t.setProtocolAddresses(address(p.reserve()), address(p.staking()), address(p.gateway()));
        Ownable2Step[4] memory four = _four(p);
        for (uint256 i; i < four.length; ++i) {
            four[i].acceptOwnership();
        }
        vm.stopPrank();
    }

    function _find(Vm.Log[] memory logs, address emitter, bytes32 topic) internal pure returns (Vm.Log memory) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == emitter && logs[i].topics[0] == topic) return logs[i];
        }
        revert("log not found");
    }

    // ---------------------------------------------------------------- the deployment

    function test_one_deployment_builds_the_four_contracts_for_the_token() public {
        address predicted = vm.computeCreateAddress(owner, vm.getNonce(owner));
        KyzenProtocol p = _deploy(_setup());
        assertEq(address(p), predicted);
        // The contract creates the four itself, in this order (a contract's first creation uses nonce 1).
        assertEq(address(p.registry()), vm.computeCreateAddress(address(p), 1));
        assertEq(address(p.reserve()), vm.computeCreateAddress(address(p), 2));
        assertEq(address(p.staking()), vm.computeCreateAddress(address(p), 3));
        assertEq(address(p.gateway()), vm.computeCreateAddress(address(p), 4));

        Reserve reserve = p.reserve();
        assertEq(address(reserve.kyzn()), address(token));
        assertEq(address(reserve.weth()), address(weth));
        assertEq(reserve.ethUsdFeed(), ethUsd);
        assertEq(uint256(reserve.ethUsdDecimals()), 8);
        assertEq(address(reserve.registry()), address(p.registry()));
        assertEq(reserve.keeper(), keeper);

        Staking staking = p.staking();
        assertEq(address(staking.kyzn()), address(token));
        assertEq(address(staking.router()), address(router));
        assertEq(address(staking.weth()), address(weth));
        assertEq(address(staking.reserve()), address(reserve));
        assertEq(staking.equityAssetA(), assetList[0].token);
        assertEq(staking.equityAssetB(), assetList[1].token);
        assertEq(staking.feeSource(), address(0)); // only the token sends Staking ETH
        assertFalse(staking.equityEnabled()); // chip equity off until counsel review

        GatewaySettlement gateway = p.gateway();
        assertEq(address(gateway.kyzn()), address(token));
        assertEq(address(gateway.router()), address(router));
        assertEq(gateway.operator(), operator);
        assertEq(gateway.hostPayout(), host);

        assertEq(p.registry().rotationCount(), 0);

        // The token is untouched: its owner sets the three next, and still holds the whole supply.
        assertEq(token.reserve(), address(0));
        assertEq(token.staking(), address(0));
        assertEq(token.gateway(), address(0));
        assertEq(token.owner(), owner);
        assertEq(token.balanceOf(owner), token.INITIAL_SUPPLY());
    }

    /// The Reserve's constructor lists all seven at once, in order, at their stages: no 24-hour
    /// queue, unlike an asset the owner adds later.
    function test_the_reserve_lists_the_seven_stock_tokens_at_deployment() public {
        vm.recordLogs();
        KyzenProtocol p = _deploy(_setup());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Reserve reserve = p.reserve();
        assertEq(reserve.assetCount(), 7);
        for (uint256 i; i < 7; ++i) {
            RobinhoodChain.Asset memory a = assetList[i];
            assertEq(reserve.assets(i), a.token);
            (address feed, uint8 feedDecimals, uint8 stage, uint64 lastTradeAt, bool listed) =
                reserve.assetInfo(a.token);
            assertEq(feed, a.feed);
            assertEq(uint256(feedDecimals), 8);
            assertEq(uint256(stage), uint256(a.stage));
            assertEq(uint256(lastTradeAt), 0);
            assertTrue(listed);
            (,, uint64 effectiveAt) = reserve.pendingAsset(a.token);
            assertEq(uint256(effectiveAt), 0);
        }
        uint256 added;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(reserve) || logs[i].topics[0] != Reserve.AssetAdded.selector) continue;
            assertEq(logs[i].topics[1], bytes32(uint256(uint160(assetList[added].token))));
            (address feed, uint8 stage) = abi.decode(logs[i].data, (address, uint8));
            assertEq(feed, assetList[added].feed);
            assertEq(uint256(stage), uint256(assetList[added].stage));
            ++added;
        }
        assertEq(added, 7);
    }

    function test_the_swap_target_is_queued_and_usable_24_hours_later() public {
        vm.recordLogs();
        KyzenProtocol p = _deploy(_setup());
        Reserve reserve = p.reserve();
        Vm.Log memory queued = _find(vm.getRecordedLogs(), address(reserve), Reserve.TargetQueued.selector);
        assertEq(queued.topics[1], bytes32(uint256(uint160(SWAP_TARGET))));
        (bool allowed, uint256 effectiveAt) = abi.decode(queued.data, (bool, uint256));
        assertTrue(allowed);
        assertEq(effectiveAt, DEPLOYED_AT + 24 hours);
        assertEq(reserve.TARGET_DELAY(), 24 hours);

        assertFalse(reserve.isTargetAllowed(SWAP_TARGET));
        vm.warp(effectiveAt - 1);
        assertFalse(reserve.isTargetAllowed(SWAP_TARGET));
        vm.warp(effectiveAt);
        assertTrue(reserve.isTargetAllowed(SWAP_TARGET));
        // Still usable once the three are set in the token (Staking becomes a forbidden target).
        _takeOver(token, p);
        assertTrue(reserve.isTargetAllowed(SWAP_TARGET));
    }

    function test_an_empty_host_payout_is_the_deploying_owner() public {
        KyzenProtocol.Setup memory s = _setup();
        s.hostPayout = address(0);
        KyzenProtocol p = _deploy(s);
        assertEq(p.gateway().hostPayout(), owner);
    }

    function test_the_deployed_event_names_the_owner_the_token_and_the_four() public {
        vm.recordLogs();
        KyzenProtocol p = _deploy(_setup());
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.emitter, address(p));
        assertEq(last.topics.length, 3);
        assertEq(last.topics[0], KyzenProtocol.Deployed.selector);
        assertEq(last.topics[1], bytes32(uint256(uint160(owner))));
        assertEq(last.topics[2], bytes32(uint256(uint160(address(token)))));
        (address registry, address reserve, address staking, address gateway) =
            abi.decode(last.data, (address, address, address, address));
        assertEq(registry, address(p.registry()));
        assertEq(reserve, address(p.reserve()));
        assertEq(staking, address(p.staking()));
        assertEq(gateway, address(p.gateway()));
        uint256 own;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(p)) ++own;
        }
        assertEq(own, 1);
    }

    // ---------------------------------------------------------------- what the owner does next

    /// Each of the four is offered to the deployer: the contract stays the owner until the deployer
    /// accepts, and no one else can accept. It has no function that could use that ownership.
    function test_ownership_of_the_four_waits_for_the_owner_to_accept_it() public {
        KyzenProtocol p = _deploy(_setup());
        Ownable2Step[4] memory four = _four(p);
        for (uint256 i; i < four.length; ++i) {
            assertEq(four[i].owner(), address(p));
            assertEq(four[i].pendingOwner(), owner);
            vm.prank(stranger);
            vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
            four[i].acceptOwnership();
        }
        vm.startPrank(owner);
        for (uint256 i; i < four.length; ++i) {
            four[i].acceptOwnership();
        }
        vm.stopPrank();
        for (uint256 i; i < four.length; ++i) {
            assertEq(four[i].owner(), owner);
            assertEq(four[i].pendingOwner(), address(0));
        }
        // The owner's powers work from then on.
        Reserve reserve = p.reserve();
        address nextKeeper = makeAddr("next keeper");
        vm.prank(owner);
        reserve.setKeeper(nextKeeper);
        assertEq(reserve.keeper(), nextKeeper);
    }

    /// The token reads back each of the three as built for it, accepts them, and from then on they
    /// are exempt from the tax. The read-backs are real checks: the same addresses in the wrong
    /// places are refused.
    function test_the_token_accepts_the_three_and_exempts_them_from_the_tax() public {
        KyzenProtocol p = _deploy(_setup());
        address reserve = address(p.reserve());
        address staking = address(p.staking());
        address gateway = address(p.gateway());
        assertFalse(token.isExempt(reserve));
        assertFalse(token.isExempt(staking));
        assertFalse(token.isExempt(gateway));

        vm.prank(owner);
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        token.setProtocolAddresses(reserve, gateway, staking);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        token.setProtocolAddresses(reserve, staking, gateway);

        vm.expectEmit(address(token));
        emit KyznToken.ProtocolAddressesSet(reserve, staking, gateway);
        vm.prank(owner);
        token.setProtocolAddresses(reserve, staking, gateway);
        assertEq(token.reserve(), reserve);
        assertEq(token.staking(), staking);
        assertEq(token.gateway(), gateway);
        assertTrue(token.isExempt(reserve));
        assertTrue(token.isExempt(staking));
        assertTrue(token.isExempt(gateway));
        assertFalse(token.isExempt(owner));
        assertFalse(token.isExempt(address(p)));
    }

    /// It takes no $KYZN and no ETH (its constructor is not payable), needs no allowance and keeps
    /// nothing; once the owner accepts, it owns nothing either.
    function test_it_keeps_nothing() public {
        KyzenProtocol p = _deploy(_setup());
        assertEq(address(p).balance, 0);
        assertEq(token.balanceOf(address(p)), 0);
        assertEq(weth.balanceOf(address(p)), 0);
        assertEq(token.allowance(owner, address(p)), 0);
        assertEq(token.balanceOf(owner), token.INITIAL_SUPPLY());
        _takeOver(token, p);
        Ownable2Step[4] memory four = _four(p);
        for (uint256 i; i < four.length; ++i) {
            assertEq(four[i].owner(), owner);
            assertEq(address(four[i]).balance, 0);
            assertEq(token.balanceOf(address(four[i])), 0);
        }
    }

    // ---------------------------------------------------------------- refusals

    /// Only the token's owner deploys it: not a stranger, and not the next owner before it accepts
    /// the token's ownership.
    function test_only_the_token_s_owner_can_deploy_it() public {
        KyzenProtocol.Setup memory s = _setup();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(KyzenProtocol.NotTokenOwner.selector, owner));
        new KyzenProtocol(s);

        address next = makeAddr("next owner");
        vm.prank(owner);
        token.transferOwnership(next);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(KyzenProtocol.NotTokenOwner.selector, owner));
        new KyzenProtocol(s);

        vm.prank(next);
        token.acceptOwnership();
        vm.prank(next);
        KyzenProtocol p = new KyzenProtocol(s);
        assertEq(p.reserve().pendingOwner(), next);
        assertEq(p.gateway().hostPayout(), host);
    }

    function test_a_renounced_token_gets_no_protocol() public {
        vm.prank(owner);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
        KyzenProtocol.Setup memory s = _setup();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KyzenProtocol.NotTokenOwner.selector, address(0)));
        new KyzenProtocol(s);
    }

    function test_each_empty_required_setting_stops_the_deployment_by_name() public {
        KyzenProtocol.Setup memory s = _setup();
        s.keeper = address(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KyzenProtocol.SettingNotSet.selector, "KEEPER"));
        new KyzenProtocol(s);

        s = _setup();
        s.operator = address(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KyzenProtocol.SettingNotSet.selector, "OPERATOR"));
        new KyzenProtocol(s);

        // Both empty: KEEPER is named first.
        s.keeper = address(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(KyzenProtocol.SettingNotSet.selector, "KEEPER"));
        new KyzenProtocol(s);
    }

    /// The Reserve's one swap-target rule applies to the queued target too.
    function test_a_forbidden_swap_target_stops_the_deployment() public {
        KyzenProtocol.Setup memory s = _setup();
        s.swapTarget = address(0);
        vm.prank(owner);
        vm.expectRevert(Reserve.BadTarget.selector);
        new KyzenProtocol(s);

        s.swapTarget = assetList[2].token; // a listed stock token
        vm.prank(owner);
        vm.expectRevert(Reserve.BadTarget.selector);
        new KyzenProtocol(s);
    }

    // ---------------------------------------------------------------- the mainnet contract

    function test_the_mainnet_protocol_runs_only_on_robinhood_chain() public {
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(WrongChain.selector, block.chainid));
        new KyzenMainnetProtocol(token, address(0), keeper, operator);
    }

    function test_the_mainnet_protocol_refuses_a_token_on_another_router() public {
        vm.chainId(RobinhoodChain.CHAIN_ID);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(NotRobinhoodToken.selector, address(router)));
        new KyzenMainnetProtocol(token, address(0), keeper, operator);
    }

    /// KyzenMainnetProtocol's own setup, offline: on chain ID 4663, with this test's Router02, feeds
    /// and stock tokens standing at their Robinhood Chain addresses (their code placed there), and
    /// the server's keeper and operator from SPEC 3.1. test/fork runs it against the real contracts.
    function test_the_mainnet_protocol_builds_on_robinhood_chain_s_addresses() public {
        KyznToken t = _robinhoodToken();
        vm.prank(owner);
        KyzenMainnetProtocol p = new KyzenMainnetProtocol(t, address(0), MAINNET_KEEPER, MAINNET_OPERATOR);

        Reserve reserve = p.reserve();
        RobinhoodChain.Asset[7] memory list = RobinhoodChain.assets();
        assertEq(reserve.assetCount(), list.length);
        for (uint256 i; i < list.length; ++i) {
            assertEq(reserve.assets(i), list[i].token);
            (address feed,, uint8 stage,, bool listed) = reserve.assetInfo(list[i].token);
            assertEq(feed, list[i].feed);
            assertEq(uint256(stage), uint256(list[i].stage));
            assertTrue(listed);
        }
        assertEq(address(reserve.kyzn()), address(t));
        assertEq(address(reserve.weth()), address(weth));
        assertEq(reserve.ethUsdFeed(), RobinhoodChain.ETH_USD_FEED);
        assertEq(reserve.keeper(), MAINNET_KEEPER);
        assertEq(address(p.staking().router()), RobinhoodChain.UNISWAP_V2_ROUTER);
        assertEq(p.staking().equityAssetA(), RobinhoodChain.NVDA);
        assertEq(p.staking().equityAssetB(), RobinhoodChain.AMD);
        assertEq(address(p.gateway().router()), RobinhoodChain.UNISWAP_V2_ROUTER);
        assertEq(p.gateway().operator(), MAINNET_OPERATOR);
        assertEq(p.gateway().hostPayout(), owner); // zero argument: the deploying owner
        assertFalse(reserve.isTargetAllowed(RobinhoodChain.UNISWAP_V3_SWAP_ROUTER_02));
        vm.warp(block.timestamp + 24 hours);
        assertTrue(reserve.isTargetAllowed(RobinhoodChain.UNISWAP_V3_SWAP_ROUTER_02));

        Ownable2Step[4] memory four = _four(p);
        for (uint256 i; i < four.length; ++i) {
            assertEq(four[i].pendingOwner(), owner);
        }
        _takeOver(t, p);
        assertEq(t.reserve(), address(reserve));
        assertTrue(t.isExempt(address(p.staking())));
        assertEq(reserve.owner(), owner);
    }

    /// Chain ID 4663, this test's Router02 at Router02's address there (its factory and WETH are
    /// this test's), a feed's code at each feed address and a stock token's at each stock token
    /// address; then the owner deploys the token on that Router02, as in step one.
    function _robinhoodToken() internal returns (KyznToken t) {
        vm.etch(RobinhoodChain.UNISWAP_V2_ROUTER, address(router).code);
        bytes memory feedCode = address(new MockFeed(8, 100e8)).code;
        bytes memory stockCode = address(new MockStockToken("STOCK")).code;
        vm.etch(RobinhoodChain.ETH_USD_FEED, feedCode);
        RobinhoodChain.Asset[7] memory list = RobinhoodChain.assets();
        for (uint256 i; i < list.length; ++i) {
            vm.etch(list[i].token, stockCode);
            vm.etch(list[i].feed, feedCode);
        }
        vm.chainId(RobinhoodChain.CHAIN_ID);
        vm.prank(owner);
        t = new KyznToken(IUniswapV2Router02(RobinhoodChain.UNISWAP_V2_ROUTER), owner);
        assertEq(t.weth(), address(weth));
    }
}
