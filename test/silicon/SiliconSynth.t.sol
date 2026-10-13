// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {SiliconSynth} from "../../src/silicon/SiliconSynth.sol";

/// One market's synth: 18 decimals, minted and burned by the vault only.
contract SiliconSynthTest is Test {
    address internal vault = makeAddr("vault");
    address internal alice = makeAddr("alice");
    SiliconSynth internal synth;

    function setUp() public {
        synth = new SiliconSynth("Kyzen Network H100-HR", "kH100", vault);
    }

    function test_metadata() public view {
        assertEq(synth.name(), "Kyzen Network H100-HR");
        assertEq(synth.symbol(), "kH100");
        assertEq(synth.decimals(), 18);
        assertEq(synth.vault(), vault);
        assertEq(synth.totalSupply(), 0);
    }

    function test_constructor_rejects_zero_vault() public {
        vm.expectRevert(SiliconSynth.ZeroAddress.selector);
        new SiliconSynth("Kyzen Network H100-HR", "kH100", address(0));
    }

    function test_only_the_vault_mints_and_burns() public {
        vm.prank(alice);
        vm.expectRevert(SiliconSynth.NotVault.selector);
        synth.mint(alice, 1);

        vm.prank(vault);
        synth.mint(alice, 5e18);
        assertEq(synth.balanceOf(alice), 5e18);

        vm.prank(alice);
        vm.expectRevert(SiliconSynth.NotVault.selector);
        synth.burn(alice, 1);

        vm.prank(vault);
        synth.burn(alice, 2e18);
        assertEq(synth.balanceOf(alice), 3e18);
        assertEq(synth.totalSupply(), 3e18);
    }

    function test_burn_above_balance_reverts() public {
        vm.prank(vault);
        synth.mint(alice, 1e18);
        vm.prank(vault);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, 1e18, 2e18));
        synth.burn(alice, 2e18);
    }

    function test_transfers_like_any_erc20() public {
        vm.prank(vault);
        synth.mint(alice, 1e18);
        vm.prank(alice);
        assertTrue(synth.transfer(vault, 4e17));
        assertEq(synth.balanceOf(vault), 4e17);
    }
}
