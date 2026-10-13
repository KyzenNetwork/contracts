// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {Reserve} from "../../src/Reserve.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {KyzenLaunch} from "../../script/KyzenLaunch.sol";
import {mainnetSetup} from "../../script/KyzenMainnetLaunch.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";
import {RecordMainnet} from "../../script/RecordMainnet.s.sol";

/// The recorder, against real Robinhood Chain mainnet state with the mainnet launch run as one
/// transaction (KyzenLaunch with KyzenMainnetLaunch's setup), as the owner deploys it from Remix.
contract RecordMainnetForkTest is Test {
    RecordMainnet internal recorder;
    IUniswapV2Router02 internal router = IUniswapV2Router02(RH.UNISWAP_V2_ROUTER);
    address internal owner = makeAddr("owner");
    address internal dev = makeAddr("dev");
    address internal team = makeAddr("team");
    address internal host = makeAddr("host");
    address internal keeper = makeAddr("keeper");
    address internal operator = makeAddr("operator");

    function setUp() public {
        vm.createSelectFork("robinhood");
        recorder = new RecordMainnet();
        vm.deal(owner, 10 ether);
    }

    function _launch() internal returns (KyzenLaunch l) {
        KyzenLaunch.Setup memory s = mainnetSetup(dev, team, host, keeper, operator);
        vm.prank(owner);
        l = new KyzenLaunch{value: 2 ether}(s);
    }

    function test_reads_every_address_from_the_token() public {
        KyzenLaunch l = _launch();
        RecordMainnet.Record memory r = recorder.read(address(l.token()));
        assertEq(r.token, address(l.token()));
        assertEq(r.pair, l.pair());
        assertEq(r.registry, address(l.registry()));
        assertEq(r.reserve, address(l.reserve()));
        assertEq(r.staking, address(l.staking()));
        assertEq(r.gateway, address(l.gateway()));
        assertEq(r.owner, owner); // pending until accepted
        assertEq(r.devWallet, dev);
        assertEq(r.hostPayout, host);
        assertEq(r.keeper, keeper);
        assertEq(r.operator, operator);

        // Fetched first: a prank applies to the very next call, which would otherwise be the getter.
        Reserve reserve = l.reserve();
        vm.prank(owner);
        reserve.acceptOwnership();
        assertEq(reserve.owner(), owner);
        assertEq(recorder.read(address(l.token())).owner, owner);
    }

    function test_refuses_a_token_whose_protocol_addresses_are_not_set() public {
        KyznToken bare = new KyznToken(router, dev);
        vm.expectRevert(RecordMainnet.NotWired.selector);
        recorder.read(address(bare));
    }

    /// A token cannot be wired to another token's contracts at all: the token refuses them.
    function test_a_token_cannot_be_wired_to_another_tokens_contracts() public {
        KyzenLaunch l = _launch();
        KyznToken stray = new KyznToken(router, dev);
        // Fetched first: vm.expectRevert covers only the very next call.
        (address r, address st, address g) = (address(l.reserve()), address(l.staking()), address(l.gateway()));
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        stray.setProtocolAddresses(r, st, g);
    }

    function test_refuses_an_address_without_code() public {
        address nothing = makeAddr("nothing");
        vm.expectRevert(abi.encodeWithSelector(RecordMainnet.NoCode.selector, "KyznToken", nothing));
        recorder.read(nothing);
    }
}
