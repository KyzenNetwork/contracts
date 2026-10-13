// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {Fixture} from "./utils/Fixture.sol";
import {ProtocolStub} from "./mocks/ProtocolStub.sol";

/// Supply, the constructor, owner powers, the protocol addresses and ownership (SPEC 3.1).
contract KyznTokenTest is Fixture {
    function test_metadata_and_fixed_supply() public view {
        assertEq(token.name(), "Kyzen Network");
        assertEq(token.symbol(), "KYZN");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.balanceOf(pair), LIQUIDITY_TOKENS);
        assertEq(token.balanceOf(address(this)), 100_000_000e18);
    }

    function test_pair_is_the_factory_pair() public view {
        assertEq(factory.getPair(address(token), address(weth)), pair);
        assertEq(token.weth(), address(weth));
        assertEq(address(token.router()), address(router));
    }

    /// A pair pre-created at the token's predicted deployment address (e.g. by a griefer front
    /// running the launch) must not block deployment: the constructor reuses it.
    function test_deploys_when_the_pair_already_exists() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address existingPair = factory.createPair(predicted, address(weth));

        KyznToken fresh = new KyznToken(IUniswapV2Router02(address(router)), dev);

        assertEq(address(fresh), predicted);
        assertEq(fresh.pair(), existingPair);
        assertEq(fresh.balanceOf(address(this)), fresh.INITIAL_SUPPLY());
    }

    function test_burn_reduces_supply() public {
        token.burn(1_000e18);
        assertEq(token.totalSupply(), 1_000_000_000e18 - 1_000e18);
    }

    function test_lowerTax_is_one_way_and_stops_at_4_percent() public {
        vm.expectEmit(address(token));
        emit KyznToken.TaxLowered(500, 1_000, 500, 700);
        token.lowerTax(500, 700);
        assertEq(token.buyTaxBps(), 500);
        assertEq(token.sellTaxBps(), 700);
        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(500, 700);
        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(500, 1_000);
        token.lowerTax(400, 400);
        assertEq(token.buyTaxBps(), 400);
        assertEq(token.sellTaxBps(), 400);
        vm.expectRevert(KyznToken.TaxNotLower.selector);
        token.lowerTax(400, 400);
        vm.expectRevert(KyznToken.TaxBelowFloor.selector);
        token.lowerTax(0, 400);
    }

    /// Before any trade: no tax held, nothing recorded for the Reserve or Staking.
    function test_starts_with_no_tax_recorded() public view {
        assertEq(token.reserveTaxTokens(), 0);
        assertEq(token.stakingTaxTokens(), 0);
        assertEq(token.balanceOf(address(token)), 0);
    }

    function test_owner_powers_are_owner_only() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.startPrank(alice);
        vm.expectRevert(unauthorized);
        token.lowerTax(400, 400);
        vm.expectRevert(unauthorized);
        token.setDevWallet(alice);
        vm.expectRevert(unauthorized);
        token.setSwapThreshold(200_000e18);
        vm.expectRevert(unauthorized);
        token.setProtocolAddresses(alice, alice, alice);
        vm.expectRevert(unauthorized);
        token.removeMaxWallet();
        vm.expectRevert(unauthorized);
        token.renounceOwnership();
        vm.stopPrank();
    }

    function test_setDevWallet() public {
        vm.expectEmit(address(token));
        emit KyznToken.DevWalletSet(bob);
        token.setDevWallet(bob);
        assertEq(token.devWallet(), bob);
        vm.expectRevert(KyznToken.ZeroAddress.selector);
        token.setDevWallet(address(0));
    }

    function test_swapThreshold_bounds() public {
        assertEq(token.swapThreshold(), 500_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.SwapThresholdSet(100_000e18);
        token.setSwapThreshold(100_000e18);
        vm.expectEmit(address(token));
        emit KyznToken.SwapThresholdSet(1_000_000e18);
        token.setSwapThreshold(1_000_000e18);
        assertEq(token.swapThreshold(), 1_000_000e18);
        vm.expectRevert(KyznToken.ThresholdOutOfRange.selector);
        token.setSwapThreshold(100_000e18 - 1);
        vm.expectRevert(KyznToken.ThresholdOutOfRange.selector);
        token.setSwapThreshold(1_000_000e18 + 1);
    }

    /// Until renouncing, the owner can point the Reserve, Staking and Gateway at new contracts; the
    /// tax exemption moves with them.
    function test_the_owner_replaces_the_protocol_addresses() public {
        assertEq(token.reserve(), address(reserve));
        assertEq(token.staking(), address(staking));
        assertEq(token.gateway(), address(gateway));
        (address r, address st, address g) = _stubs(token);
        vm.expectEmit(address(token));
        emit KyznToken.ProtocolAddressesSet(r, st, g);
        token.setProtocolAddresses(r, st, g);
        assertEq(token.reserve(), r);
        assertEq(token.staking(), st);
        assertEq(token.gateway(), g);
        assertTrue(token.isExempt(r));
        assertFalse(token.isExempt(address(reserve)));
        // Still checked as before: the new set must read back as built for this token.
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        token.setProtocolAddresses(alice, bob, carol);
        token.renounceOwnership();
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        token.setProtocolAddresses(address(reserve), address(staking), address(gateway));
    }

    function test_protocol_addresses_must_be_nonzero() public {
        KyznToken fresh = new KyznToken(IUniswapV2Router02(address(router)), dev);
        (address r, address s, address g) = _stubs(fresh);
        vm.expectRevert(KyznToken.ZeroAddress.selector);
        fresh.setProtocolAddresses(address(0), s, g);
        vm.expectRevert(KyznToken.ZeroAddress.selector);
        fresh.setProtocolAddresses(r, address(0), g);
        vm.expectRevert(KyznToken.ZeroAddress.selector);
        fresh.setProtocolAddresses(r, s, address(0));
        assertEq(fresh.reserve(), address(0));
    }

    /// Never the pair, the token, WETH, the router, or a duplicate of one of the other two.
    function test_setProtocolAddresses_rejects_reserved_or_duplicate_addresses() public {
        KyznToken fresh = new KyznToken(IUniswapV2Router02(address(router)), dev);
        // Fetched up front: vm.expectRevert only covers the very next call, and reading these
        // as inline arguments below would itself be that next (non-reverting) call.
        address freshPair = fresh.pair();
        address freshWeth = fresh.weth();
        address freshRouter = address(fresh.router());
        (address goodA, address goodB, address goodC) = _stubs(fresh);

        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(freshPair, goodB, goodC);

        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(goodA, address(fresh), goodC);

        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(goodA, goodB, freshWeth);

        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(freshRouter, goodB, goodC);

        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(goodA, goodA, goodC);

        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(goodA, goodB, goodA);

        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(goodA, goodB, goodB);

        fresh.setProtocolAddresses(goodA, goodB, goodC);
        assertEq(fresh.reserve(), goodA);
        assertEq(fresh.staking(), goodB);
        assertEq(fresh.gateway(), goodC);
    }

    /// Each address must read back as the contract it is set as, built for this token: wallets,
    /// a swapped order, and contracts pointing at another token, Reserve or router are refused.
    function test_setProtocolAddresses_requires_contracts_built_for_this_token() public {
        KyznToken fresh = new KyznToken(IUniswapV2Router02(address(router)), dev);
        (address r, address s, address g) = _stubs(fresh);
        address freshWeth = fresh.weth();
        address freshRouter = address(fresh.router());

        // Wallets: nothing to read back.
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(alice, bob, carol);
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(r, s, carol);

        // The right contracts in the wrong slots.
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(s, r, g);
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(r, g, s);

        // Built for another token: the fixture's live Reserve, Staking and Gateway.
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(address(reserve), address(staking), address(gateway));

        // One wrong read each.
        address reserveOtherWeth = address(new ProtocolStub(address(fresh), alice, address(0), address(0)));
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(reserveOtherWeth, s, g);
        address stakingOtherReserve = address(new ProtocolStub(address(fresh), address(0), alice, freshRouter));
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(r, stakingOtherReserve, g);
        address stakingOtherRouter = address(new ProtocolStub(address(fresh), address(0), r, alice));
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(r, stakingOtherRouter, g);
        address gatewayOtherRouter = address(new ProtocolStub(address(fresh), address(0), address(0), alice));
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(r, s, gatewayOtherRouter);
        address gatewayOtherToken = address(new ProtocolStub(address(token), address(0), address(0), freshRouter));
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(r, s, gatewayOtherToken);

        assertEq(fresh.reserve(), address(0));
        vm.expectEmit(address(fresh));
        emit KyznToken.ProtocolAddressesSet(r, s, g);
        fresh.setProtocolAddresses(r, s, g);
        assertEq(fresh.reserve(), r);
        assertEq(fresh.staking(), s);
        assertEq(fresh.gateway(), g);
        assertEq(freshWeth, address(weth));
    }

    /// The development wallet can never be a protocol contract (none of them can claim the share
    /// held for it): each of the Reserve, Staking and Gateway slots is refused, for the addresses
    /// set at the start and again for the ones that replace them.
    function test_setDevWallet_refuses_the_protocol_contracts() public {
        _expectEachRefusedAsDevWallet([address(reserve), address(staking), address(gateway)]);
        (address r, address st, address g) = _stubs(token);
        token.setProtocolAddresses(r, st, g);
        _expectEachRefusedAsDevWallet([r, st, g]);
        assertEq(token.devWallet(), dev);
        token.setDevWallet(alice);
        assertEq(token.devWallet(), alice);
    }

    function _expectEachRefusedAsDevWallet(address[3] memory protocol) internal {
        for (uint256 i; i < protocol.length; ++i) {
            vm.expectRevert(KyznToken.BadDevWallet.selector);
            token.setDevWallet(protocol[i]);
        }
    }

    function test_setProtocolAddresses_refuses_the_development_wallet() public {
        KyznToken fresh = new KyznToken(IUniswapV2Router02(address(router)), dev);
        (address r, address s, address g) = _stubs(fresh);
        fresh.setDevWallet(g); // allowed while no protocol address is set
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(r, s, g);
        fresh.setDevWallet(dev);
        fresh.setProtocolAddresses(r, s, g);
        assertEq(fresh.gateway(), g);
    }

    /// Duplicates are refused even when every read-back matches: one stub that answers as the Reserve,
    /// as Staking (its `reserve()` is itself) and as the Gateway isolates the duplicate rule. (The
    /// reserved addresses, by contrast, also fail the read-backs: the reserved check is a second line.)
    function test_setProtocolAddresses_refuses_duplicates_that_pass_every_read_back() public {
        KyznToken fresh = new KyznToken(IUniswapV2Router02(address(router)), dev);
        address freshRouter = address(fresh.router());
        address x = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        assertEq(address(new ProtocolStub(address(fresh), fresh.weth(), x, freshRouter)), x);
        address y = address(new ProtocolStub(address(fresh), address(0), x, freshRouter)); // Staking for x
        (,, address g) = _stubs(fresh);

        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(x, x, g); // reserve == staking
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(x, y, x); // reserve == gateway
        vm.expectRevert(KyznToken.BadProtocolAddress.selector);
        fresh.setProtocolAddresses(x, y, y); // staking == gateway
        fresh.setProtocolAddresses(x, y, g);
        assertEq(fresh.staking(), y);
    }

    /// The development share in ETH would be lost at the pair, the token, WETH or the router.
    function test_dev_wallet_is_never_a_reserved_address() public {
        IUniswapV2Router02 r = IUniswapV2Router02(address(router));
        vm.expectRevert(KyznToken.BadDevWallet.selector);
        new KyznToken(r, address(weth));
        vm.expectRevert(KyznToken.BadDevWallet.selector);
        new KyznToken(r, address(router));
        // The token itself (its predicted address), and its pair (pre-created for that address,
        // as the constructor finds it). A failed creation still uses up a nonce, so each case
        // predicts afresh.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(KyznToken.BadDevWallet.selector);
        new KyznToken(r, predicted);
        predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        address prePair = factory.createPair(predicted, address(weth));
        vm.expectRevert(KyznToken.BadDevWallet.selector);
        new KyznToken(r, prePair);

        vm.expectRevert(KyznToken.BadDevWallet.selector);
        token.setDevWallet(pair);
        vm.expectRevert(KyznToken.BadDevWallet.selector);
        token.setDevWallet(address(token));
        vm.expectRevert(KyznToken.BadDevWallet.selector);
        token.setDevWallet(address(weth));
        vm.expectRevert(KyznToken.BadDevWallet.selector);
        token.setDevWallet(address(router));
        assertEq(token.devWallet(), dev);
    }

    function test_renouncing_is_allowed_any_time_and_removes_the_max_wallet() public {
        assertTrue(token.maxWalletActive());
        vm.expectEmit(address(token));
        emit KyznToken.MaxWalletRemoved();
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
        assertFalse(token.maxWalletActive());
    }

    function test_the_owner_removes_the_max_wallet_once() public {
        vm.expectEmit(address(token));
        emit KyznToken.MaxWalletRemoved();
        token.removeMaxWallet();
        assertFalse(token.maxWalletActive());
        vm.expectRevert(KyznToken.MaxWalletAlreadyRemoved.selector);
        token.removeMaxWallet();

        // Renouncing afterwards has nothing left to remove: no second MaxWalletRemoved.
        vm.recordLogs();
        token.renounceOwnership();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(logs.length, 1);
        assertEq(logs[0].topics[0], Ownable.OwnershipTransferred.selector);
        assertFalse(token.maxWalletActive());
        assertEq(token.owner(), address(0));
    }

    /// Renouncing with a transfer pending cancels it: the pending owner can no longer accept.
    function test_renouncing_cancels_a_pending_ownership_transfer() public {
        token.transferOwnership(alice);
        assertEq(token.pendingOwner(), alice);
        token.renounceOwnership();
        assertEq(token.owner(), address(0));
        assertEq(token.pendingOwner(), address(0));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        token.acceptOwnership();
        assertEq(token.owner(), address(0));
    }

    function test_liquidity_add_was_untaxed() public view {
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(pair), LIQUIDITY_TOKENS);
        assertEq(weth.balanceOf(pair), 2 ether);
    }

    /// Trading is open from deployment: no switch, any holder transfers and buys at once.
    function test_trading_is_open_from_deployment() public {
        assertEq(token.launchedAt(), block.timestamp);
        token.transfer(alice, 1_000e18);
        vm.prank(alice);
        token.transfer(bob, 1);
        assertEq(token.balanceOf(bob), 1);
        uint256 gross = 0.001 ether * router.TOKENS_PER_ETH();
        assertEq(_buy(carol, 0.001 ether), gross - gross * 500 / 10_000); // the 5% launch buy tax
    }

    /// The first liquidity went into an empty pool untaxed (setUp); from then on every pool trade
    /// is taxed, the deployer's and the owner's included.
    function test_the_deployer_is_taxed_once_the_pool_has_liquidity() public {
        assertFalse(token.isExempt(address(this)));
        _sell(address(this), 1_000_000e18);
        assertEq(token.balanceOf(address(token)), 100_000e18); // the 10% launch sell tax
    }

    function test_isExempt() public view {
        assertTrue(token.isExempt(address(token)));
        assertTrue(token.isExempt(address(reserve)));
        assertTrue(token.isExempt(address(staking)));
        assertTrue(token.isExempt(address(gateway)));
        assertFalse(token.isExempt(address(0)));
        assertFalse(token.isExempt(address(this)));
        assertFalse(token.isExempt(pair));
    }

    function test_constructor_rejects_zero_addresses() public {
        vm.expectRevert(KyznToken.ZeroAddress.selector);
        new KyznToken(IUniswapV2Router02(address(0)), dev);
        vm.expectRevert(KyznToken.ZeroAddress.selector);
        new KyznToken(IUniswapV2Router02(address(router)), address(0));
    }

    /// The constructor announces the first development wallet as setDevWallet does.
    function test_the_constructor_emits_the_development_wallet() public {
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectEmit(predicted);
        emit KyznToken.DevWalletSet(dev);
        KyznToken fresh = new KyznToken(IUniswapV2Router02(address(router)), dev);
        assertEq(address(fresh), predicted);
        assertEq(fresh.devWallet(), dev);
    }

    /// Stand-ins for the Reserve, Staking and the Gateway that read back `fresh` the way the real
    /// contracts do, so setProtocolAddresses accepts them.
    function _stubs(KyznToken fresh) internal returns (address r, address s, address g) {
        r = address(new ProtocolStub(address(fresh), fresh.weth(), address(0), address(0)));
        s = address(new ProtocolStub(address(fresh), address(0), r, address(fresh.router())));
        g = address(new ProtocolStub(address(fresh), address(0), address(0), address(fresh.router())));
    }
}
