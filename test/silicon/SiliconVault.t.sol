// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {SiliconSynth} from "../../src/silicon/SiliconSynth.sol";
import {SiliconFeed} from "../../src/silicon/SiliconFeed.sol";
import {ISiliconSynth} from "../../src/silicon/interfaces/ISiliconSynth.sol";
import {ISiliconFeed} from "../../src/silicon/interfaces/ISiliconFeed.sol";
import {IKyznUsdOracle} from "../../src/silicon/interfaces/IKyznUsdOracle.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {MockToken, MockKyznOracle, MockSiliconFeed, CallbackToken} from "./mocks/SiliconMocks.sol";
import {SiliconFixture} from "./utils/SiliconFixture.sol";

/// SiliconVault: owner settings, opening a market, and positions (SPEC 3.5).
/// Prices: $KYZN $1.00, the synth $2.00, USDG $1.00 with 6 decimals. Mint fee 0.5%, borrow fee 5% a
/// year (test levels).
contract SiliconVaultTest is SiliconFixture {
    // ================================================================ construction

    function test_constructor() public view {
        assertEq(address(vault.kyzn()), address(kyzn));
        assertEq(address(vault.usdg()), address(usdg));
        assertEq(address(vault.oracle()), address(oracle));
        assertEq(vault.usdgScale(), 1e12);
        assertEq(vault.owner(), address(this));
        assertEq(vault.COLLATERAL_RATIO_BPS(), 15_000);
        assertEq(vault.MIN_KYZN_SHARE_BPS(), 5_000);
    }

    function test_constructor_rules() public {
        IERC20 k = IERC20(address(kyzn));
        IERC20 u = IERC20(address(usdg));
        IKyznUsdOracle o = IKyznUsdOracle(address(oracle));
        vm.expectRevert(SiliconVault.ZeroAddress.selector);
        new SiliconVault(IERC20(address(0)), u, o);
        vm.expectRevert(SiliconVault.ZeroAddress.selector);
        new SiliconVault(k, IERC20(address(0)), o);
        vm.expectRevert(SiliconVault.ZeroAddress.selector);
        new SiliconVault(k, u, IKyznUsdOracle(address(0)));
        vm.expectRevert(SiliconVault.BadCollateral.selector);
        new SiliconVault(k, k, o);
        IERC20 wide = IERC20(address(new MockToken("WIDE", 19)));
        vm.expectRevert(SiliconVault.BadCollateral.selector);
        new SiliconVault(k, wide, o);
        IERC20 eighteen = IERC20(address(new MockToken("USD18", 18)));
        assertEq(new SiliconVault(k, eighteen, o).usdgScale(), 1);
    }

    // ================================================================ markets and settings

    function _freshMarket() internal returns (uint256 newId, SiliconSynth s) {
        s = new SiliconSynth("Kyzen Network B200-HR", "kB200", address(vault));
        newId = vault.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(feed)));
    }

    function test_addMarket() public {
        SiliconSynth s = new SiliconSynth("Kyzen Network B200-HR", "kB200", address(vault));
        vm.expectEmit(address(vault));
        emit SiliconVault.MarketAdded(1, address(s), address(feed));
        uint256 newId = vault.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(feed)));
        assertEq(newId, 1);
        assertEq(vault.marketCount(), 2);
        assertTrue(vault.synthListed(address(s)));
        SiliconVault.Market memory m = vault.market(newId);
        assertEq(address(m.synth), address(s));
        assertEq(address(m.feed), address(feed));
        assertFalse(m.open);
        assertEq(m.settings, 0);
    }

    function test_addMarket_rules() public {
        SiliconSynth s = new SiliconSynth("Kyzen Network B200-HR", "kB200", address(vault));
        SiliconSynth elsewhere = new SiliconSynth("Other", "OTH", makeAddr("otherVault"));
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        vault.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(feed)));
        vm.expectRevert(SiliconVault.ZeroAddress.selector);
        vault.addMarket(ISiliconSynth(address(0)), ISiliconFeed(address(feed)));
        vm.expectRevert(SiliconVault.ZeroAddress.selector);
        vault.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(0)));
        vm.expectRevert(SiliconVault.BadSynth.selector);
        vault.addMarket(ISiliconSynth(address(elsewhere)), ISiliconFeed(address(feed)));
        vm.expectRevert(SiliconVault.BadSynth.selector);
        vault.addMarket(ISiliconSynth(address(synth)), ISiliconFeed(address(feed))); // already market 0
    }

    /// A new vault has nothing set; each setter clears its bit, and only then can a market open.
    /// The feed is ready, so the bits left are the five per-market levels and the four vault-wide
    /// ones: 1 + 2 + 4 + 8 + 512 + 16 + 32 + 64 + 256 = 895.
    function test_a_market_opens_only_once_every_setting_is_set() public {
        SiliconVault v = new SiliconVault(IERC20(address(kyzn)), IERC20(address(usdg)), IKyznUsdOracle(address(oracle)));
        SiliconSynth s = new SiliconSynth("Kyzen Network H100-HR", "kH100", address(v));
        uint256 m = v.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(feed)));
        assertEq(v.unsetSettings(m), 895);

        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingsUnset.selector, m, uint16(895)));
        v.openMarket(m);

        v.setMintFee(m, 0); // zero is a setting like any other
        v.setBorrowFee(m, 0);
        assertEq(v.unsetSettings(m), 895 - 1 - 2);
        v.setLiquidationPenalty(m, 0);
        v.setDebtCeiling(m, 0);
        v.setMinDebt(m, 1);
        assertEq(v.unsetSettings(m), 16 + 32 + 64 + 256);
        v.setAuctionDuration(1);
        v.setAuctionStartPremium(0);
        assertEq(v.unsetSettings(m), 64 + 256);
        v.setAuctionFloor(1);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingsUnset.selector, m, uint16(64)));
        v.openMarket(m);
        v.setFeeRouter(feeRouter);
        assertEq(v.unsetSettings(m), 0);

        vm.expectEmit(address(v));
        emit SiliconVault.MarketOpened(m);
        v.openMarket(m);
        assertTrue(v.market(m).open);
        assertEq(v.market(m).lastDrip, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.MarketAlreadyOpen.selector, m));
        v.openMarket(m);
    }

    /// The auction floor is a vault-wide setting like the premium: a fresh vault reports bit 256
    /// as unset until the floor is set, and a market with everything else set cannot open
    /// without it.
    function test_a_market_needs_the_auction_floor() public {
        assertEq(vault.SETTING_AUCTION_FLOOR(), 256);
        assertEq(vault.ALL_SETTINGS(), 1023);

        SiliconVault v = new SiliconVault(IERC20(address(kyzn)), IERC20(address(usdg)), IKyznUsdOracle(address(oracle)));
        SiliconSynth s = new SiliconSynth("Kyzen Network H100-HR", "kH100", address(v));
        uint256 m = v.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(feed)));
        assertTrue(v.unsetSettings(m) & 256 != 0, "bit 256 unset on a fresh vault");
        assertEq(v.vaultSettings(), 0);

        v.setMintFee(m, MINT_FEE_BPS);
        v.setBorrowFee(m, BORROW_FEE_BPS);
        v.setLiquidationPenalty(m, PENALTY_BPS);
        v.setDebtCeiling(m, CEILING);
        v.setMinDebt(m, MIN_DEBT);
        v.setAuctionDuration(AUCTION_DURATION);
        v.setAuctionStartPremium(START_PREMIUM_BPS);
        v.setFeeRouter(feeRouter);
        assertEq(v.unsetSettings(m), 256, "only the floor is left");
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingsUnset.selector, m, uint16(256)));
        v.openMarket(m);

        v.setAuctionFloor(AUCTION_FLOOR_BPS);
        assertEq(v.unsetSettings(m) & 256, 0, "bit 256 cleared");
        assertEq(v.unsetSettings(m), 0);
        v.openMarket(m);
        assertTrue(v.market(m).open);
    }

    /// Vault-wide settings count for every market; each market still needs its own five.
    function test_second_market_needs_its_own_settings() public {
        (uint256 m,) = _freshMarket();
        assertEq(vault.unsetSettings(m), 527);
        _configureMarket(m);
        assertEq(vault.unsetSettings(m), 0);
    }

    /// Audit: the feed's reporter, guardian and methodology are settings the market needs
    /// (design: required before a market opens; SPEC 3.7: methodology first). Without a guardian
    /// the dispute window protects nothing.
    function test_a_market_needs_a_configured_feed() public {
        SiliconFeed f = new SiliconFeed("B200-HR / USD", 30 minutes, 2 hours);
        SiliconSynth s = new SiliconSynth("Kyzen Network B200-HR", "kB200", address(vault));
        uint256 m = vault.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(f)));
        _configureMarket(m);
        assertEq(vault.unsetSettings(m), 128);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingsUnset.selector, m, uint16(128)));
        vault.openMarket(m);

        f.setReporter(makeAddr("reporter"));
        f.setMethodology("https://kyzen.network/docs/silicon/b200-hr", keccak256("methodology"));
        assertEq(vault.unsetSettings(m), 128, "still no guardian");
        f.setGuardian(makeAddr("guardian"));
        assertEq(vault.unsetSettings(m), 0);
        vault.openMarket(m);
        assertTrue(vault.market(m).open);
    }

    /// The market's feed says when it may back an open market: SETTING_FEED stays unset, and
    /// openMarket reverts with it, until the feed is ready, whatever its roles are.
    function test_a_market_opens_only_once_its_feed_is_ready() public {
        MockSiliconFeed f = new MockSiliconFeed(SYNTH_USD, FEED_MAX_AGE);
        SiliconSynth s = new SiliconSynth("Kyzen Network B200-HR", "kB200", address(vault));
        uint256 m = vault.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(f)));
        _configureMarket(m);
        assertFalse(f.ready());
        uint16 unset = vault.unsetSettings(m);
        assertEq(unset, vault.SETTING_FEED());
        assertEq(unset, 128);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingsUnset.selector, m, uint16(128)));
        vault.openMarket(m);

        f.setReady(true);
        assertEq(vault.unsetSettings(m), 0);
        vault.openMarket(m);
        assertTrue(vault.market(m).open);
    }

    /// Readiness is the feed's to decide: a feed with all three roles set but not ready keeps its
    /// market closed, and one that is ready opens whatever the roles say.
    function test_the_vault_reads_readiness_and_not_the_roles() public {
        MockSiliconFeed f = new MockSiliconFeed(SYNTH_USD, FEED_MAX_AGE);
        SiliconSynth s = new SiliconSynth("Kyzen Network B200-HR", "kB200", address(vault));
        uint256 m = vault.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(f)));
        _configureMarket(m);
        assertTrue(f.reporter() != address(0) && f.guardian() != address(0) && f.methodologyHash() != 0);
        assertEq(vault.unsetSettings(m), 128, "roles set, feed not ready");

        f.setRoles(address(0), address(0), bytes32(0));
        f.setReady(true);
        assertEq(vault.unsetSettings(m), 0, "ready without roles");
        f.setReady(false);
        assertEq(vault.unsetSettings(m), 128, "readiness taken back");
    }

    function test_settings_store_and_emit() public {
        (uint256 m,) = _freshMarket();
        vm.expectEmit(address(vault));
        emit SiliconVault.MintFeeSet(m, 30);
        vault.setMintFee(m, 30);
        vm.expectEmit(address(vault));
        emit SiliconVault.BorrowFeeSet(m, 400);
        vault.setBorrowFee(m, 400);
        vm.expectEmit(address(vault));
        emit SiliconVault.LiquidationPenaltySet(m, 800);
        vault.setLiquidationPenalty(m, 800);
        vm.expectEmit(address(vault));
        emit SiliconVault.DebtCeilingSet(m, 5e24);
        vault.setDebtCeiling(m, 5e24);
        SiliconVault.Market memory mk = vault.market(m);
        assertEq(mk.mintFeeBps, 30);
        assertEq(mk.borrowFeeBpsPerYear, 400);
        assertEq(mk.liquidationPenaltyBps, 800);
        assertEq(mk.debtCeiling, 5e24);
        assertEq(mk.settings, 15);

        vm.expectEmit(address(vault));
        emit SiliconVault.MinDebtSet(m, 5e18);
        vault.setMinDebt(m, 5e18);
        mk = vault.market(m);
        assertEq(mk.minDebt, 5e18);
        assertEq(mk.settings, 527);

        // The vault-wide settings apply at once on a vault with no market open (once one is, they
        // queue: SiliconVaultSettings.t.sol).
        SiliconVault v = _vaultWithNoMarketOpen();
        vm.expectEmit(address(v));
        emit SiliconVault.AuctionDurationSet(3 hours);
        v.setAuctionDuration(3 hours);
        vm.expectEmit(address(v));
        emit SiliconVault.AuctionStartPremiumSet(1_500);
        v.setAuctionStartPremium(1_500);
        vm.expectEmit(address(v));
        emit SiliconVault.AuctionFloorSet(3_500);
        v.setAuctionFloor(3_500);
        address router2 = makeAddr("router2");
        vm.expectEmit(address(v));
        emit SiliconVault.FeeRouterSet(router2);
        v.setFeeRouter(router2);
        assertEq(v.auctionDuration(), 3 hours);
        assertEq(v.auctionStartPremiumBps(), 1_500);
        assertEq(v.auctionFloorBps(), 3_500);
        assertEq(v.feeRouter(), router2);
        assertEq(v.vaultSettings(), 16 + 32 + 64 + 256);
    }

    function _vaultWithNoMarketOpen() internal returns (SiliconVault) {
        return new SiliconVault(IERC20(address(kyzn)), IERC20(address(usdg)), IKyznUsdOracle(address(oracle)));
    }

    function test_settings_rules() public {
        vm.startPrank(alice);
        bytes memory notOwner = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice);
        vm.expectRevert(notOwner);
        vault.setMintFee(id, 1);
        vm.expectRevert(notOwner);
        vault.setBorrowFee(id, 1);
        vm.expectRevert(notOwner);
        vault.setLiquidationPenalty(id, 1);
        vm.expectRevert(notOwner);
        vault.setDebtCeiling(id, 1);
        vm.expectRevert(notOwner);
        vault.setMinDebt(id, 1);
        vm.expectRevert(notOwner);
        vault.setAuctionDuration(1);
        vm.expectRevert(notOwner);
        vault.setAuctionStartPremium(1);
        vm.expectRevert(notOwner);
        vault.setAuctionFloor(1);
        vm.expectRevert(notOwner);
        vault.setFeeRouter(alice);
        vm.expectRevert(notOwner);
        vault.openMarket(id);
        vm.expectRevert(notOwner);
        vault.pauseMints(id);
        vm.expectRevert(notOwner);
        vault.unpauseMints(id);
        vm.stopPrank();

        bytes memory tooHigh = abi.encodeWithSelector(SiliconVault.BpsAboveMaximum.selector, 10_001, 10_000);
        vm.expectRevert(tooHigh);
        vault.setMintFee(id, 10_001);
        vm.expectRevert(tooHigh);
        vault.setBorrowFee(id, 10_001);
        vm.expectRevert(tooHigh);
        vault.setLiquidationPenalty(id, 10_001);
        vm.expectRevert(tooHigh);
        vault.setAuctionStartPremium(10_001);
        vault.setMintFee(id, 10_000); // 100% is the most

        // The floor is a share of the oracle value, below the full 100%, and never zero (shown
        // on a vault with no market open, where it applies at once).
        SiliconVault v = _vaultWithNoMarketOpen();
        vm.expectRevert(SiliconVault.ZeroAmount.selector);
        v.setAuctionFloor(0);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.BpsAboveMaximum.selector, 10_000, 9_999));
        v.setAuctionFloor(10_000);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.BpsAboveMaximum.selector, 10_001, 9_999));
        v.setAuctionFloor(10_001);
        v.setAuctionFloor(9_999); // 99.99% is the most
        assertEq(v.auctionFloorBps(), 9_999);
        v.setAuctionFloor(1); // and 0.01% the least
        assertEq(v.auctionFloorBps(), 1);

        vm.expectRevert(SiliconVault.ZeroAmount.selector);
        vault.setMinDebt(id, 0); // a minimum of nothing is no minimum: the setting is a real amount

        vm.expectRevert(SiliconVault.BadDuration.selector);
        vault.setAuctionDuration(0);
        vm.expectRevert(SiliconVault.ZeroAddress.selector);
        vault.setFeeRouter(address(0));
    }

    function test_unknown_market() public {
        bytes memory unknown = abi.encodeWithSelector(SiliconVault.UnknownMarket.selector, 9);
        vm.expectRevert(unknown);
        vault.setMintFee(9, 1);
        vm.expectRevert(unknown);
        vault.setBorrowFee(9, 1);
        vm.expectRevert(unknown);
        vault.setLiquidationPenalty(9, 1);
        vm.expectRevert(unknown);
        vault.setDebtCeiling(9, 1);
        vm.expectRevert(unknown);
        vault.setMinDebt(9, 1);
        vm.expectRevert(unknown);
        vault.openMarket(9);
        vm.expectRevert(unknown);
        vault.pauseMints(9);
        vm.expectRevert(unknown);
        vault.unpauseMints(9);
        vm.expectRevert(unknown);
        vault.market(9);
        vm.expectRevert(unknown);
        vault.unsetSettings(9);
        vm.expectRevert(unknown);
        vault.debtOf(9, alice);
        vm.expectRevert(unknown);
        vault.health(9, alice);
        vm.startPrank(alice);
        vm.expectRevert(unknown);
        vault.deposit(9, 1, 0);
        vm.expectRevert(unknown);
        vault.withdraw(9, 1, 0);
        vm.expectRevert(unknown);
        vault.mint(9, 1);
        vm.expectRevert(unknown);
        vault.repay(9, 1);
        vm.expectRevert(unknown);
        vault.drip(9);
        vm.expectRevert(unknown);
        vault.startAuction(bob, 9);
        vm.expectRevert(unknown);
        vault.coverBadDebt(9, 1);
        vm.stopPrank();
    }

    function test_closed_market_takes_no_deposit_or_mint() public {
        (uint256 m,) = _freshMarket();
        _configureMarket(m);
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.MarketNotOpen.selector, m));
        vault.deposit(m, 1e18, 0);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.MarketNotOpen.selector, m));
        vault.mint(m, 1e18);
        vm.stopPrank();
    }

    function test_ownership_moves_in_two_steps() public {
        vault.transferOwnership(alice);
        assertEq(vault.owner(), address(this));
        vm.prank(alice);
        vault.acceptOwnership();
        assertEq(vault.owner(), alice);
    }

    // ================================================================ deposit and withdraw

    function test_deposit() public {
        vm.expectEmit(address(vault));
        emit SiliconVault.Deposited(id, alice, 300e18, 50 * USDG_UNIT);
        _deposit(alice, 300e18, 50 * USDG_UNIT);
        (uint256 k, uint256 u, uint256 shares) = _position(alice);
        assertEq(k, 300e18);
        assertEq(u, 50 * USDG_UNIT);
        assertEq(shares, 0);
        assertEq(kyzn.balanceOf(address(vault)), 300e18);
        assertEq(usdg.balanceOf(address(vault)), 50 * USDG_UNIT);

        _deposit(alice, 0, 1);
        (, u,) = _position(alice);
        assertEq(u, 50 * USDG_UNIT + 1);

        vm.prank(alice);
        vm.expectRevert(SiliconVault.ZeroAmount.selector);
        vault.deposit(id, 0, 0);
    }

    /// Deposit reads no price: it works with the feed stale, the oracle down and mints paused.
    function test_deposit_always_works() public {
        feed.setUpdatedAt(block.timestamp - FEED_MAX_AGE - 1);
        oracle.setUnavailable(true);
        vault.pauseMints(id);
        _deposit(alice, 1e18, 1);
        (uint256 k,,) = _position(alice);
        assertEq(k, 1e18);
    }

    function test_withdraw_without_debt_reads_no_price() public {
        _deposit(alice, 300e18, 50 * USDG_UNIT);
        feed.setUpdatedAt(block.timestamp - FEED_MAX_AGE - 1);
        oracle.setUnavailable(true);
        uint256 before = kyzn.balanceOf(alice);
        vm.expectEmit(address(vault));
        emit SiliconVault.Withdrawn(id, alice, 300e18, 50 * USDG_UNIT);
        _withdraw(alice, 300e18, 50 * USDG_UNIT);
        assertEq(kyzn.balanceOf(alice), before + 300e18);
        (uint256 k, uint256 u,) = _position(alice);
        assertEq(k + u, 0);
        assertEq(oracle.updates(), 0);
    }

    function test_withdraw_rules() public {
        _deposit(alice, 300e18, 50 * USDG_UNIT);
        vm.startPrank(alice);
        vm.expectRevert(SiliconVault.ZeroAmount.selector);
        vault.withdraw(id, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.InsufficientKyzn.selector, 300e18, 300e18 + 1));
        vault.withdraw(id, 300e18 + 1, 0);
        vm.expectRevert(
            abi.encodeWithSelector(SiliconVault.InsufficientUsdg.selector, 50 * USDG_UNIT, 50 * USDG_UNIT + 1)
        );
        vault.withdraw(id, 0, 50 * USDG_UNIT + 1);
        vm.stopPrank();
    }

    /// 300 $KYZN against 90.45 synth of debt ($180.90): withdrawing 30 leaves 149.2%.
    function test_withdraw_keeps_the_ratio() public {
        _deposit(alice, 300e18, 0);
        _mint(alice, 90e18); // debt 90.45
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, 14_925, 15_000));
        vault.withdraw(id, 30e18, 0);
        _withdraw(alice, 20e18, 0); // 280 / 180.90 = 154.7%
        (uint256 k,,) = _position(alice);
        assertEq(k, 280e18);
    }

    /// 200 $KYZN and 200 USDG: taking out 50 $KYZN leaves $KYZN at 42.8% of collateral.
    function test_withdraw_keeps_the_kyzn_share() public {
        _deposit(alice, 200e18, 200 * USDG_UNIT);
        _mint(alice, 50e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.KyznShareTooLow.selector, 4_285, 5_000));
        vault.withdraw(id, 50e18, 0);
        _withdraw(alice, 0, 200 * USDG_UNIT); // USDG out only raises the share
        _withdraw(alice, 10e18, 0);
    }

    function test_withdraw_with_debt_needs_fresh_prices() public {
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 10e18);
        feed.setUpdatedAt(block.timestamp - FEED_MAX_AGE - 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.withdraw(id, 1e18, 0);

        feed.set(SYNTH_USD);
        oracle.setUnavailable(true);
        vm.prank(alice);
        vm.expectRevert(MockKyznOracle.OracleUnavailable.selector);
        vault.withdraw(id, 1e18, 0);
    }

    // ================================================================ mint

    function test_mint() public {
        _deposit(alice, 300e18, 0);
        uint256 updates = oracle.updates();
        vm.expectEmit(address(vault));
        emit SiliconVault.Minted(id, alice, 99e18, 0.495e18);
        _mint(alice, 99e18);

        assertEq(synth.balanceOf(alice), 99e18);
        assertEq(synth.balanceOf(feeRouter), 0.495e18);
        assertEq(vault.debtOf(id, alice), 99.495e18);
        (,, uint256 shares) = _position(alice);
        assertEq(shares, 99.495e18, "the first mint's shares are its debt");
        SiliconVault.Market memory m = _market();
        assertEq(m.totalDebt, 99.495e18);
        assertEq(m.totalShares, 99.495e18);
        assertEq(oracle.updates(), updates + 1, "the vault records a $KYZN observation");
        _assertSupplyIsDebt();
    }

    function test_mint_rules() public {
        _deposit(alice, 300e18, 0);
        vm.startPrank(alice);
        vm.expectRevert(SiliconVault.ZeroAmount.selector);
        vault.mint(id, 0);
        // 100 synth + 0.5 fee = $201 of debt against $300: 149.2%.
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, 14_925, 15_000));
        vault.mint(id, 100e18);
        vm.stopPrank();
    }

    /// The ratio at exactly 150% passes; one step past it does not.
    function test_mint_at_the_boundary() public {
        _deposit(alice, 300e18, 0);
        vm.prank(alice);
        // 99.51 + 0.49755 fee = $200.0151 of debt: 149.98%.
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, 14_998, 15_000));
        vault.mint(id, 99.51e18);
        _mint(alice, 99.5e18); // debt 99.9975 = $199.995: 150.0%
        (,, uint256 ratioBps,) = vault.health(id, alice);
        assertEq(ratioBps, 15_000);
    }

    function test_mint_needs_half_kyzn() public {
        _deposit(alice, 100e18, 200 * USDG_UNIT); // $KYZN 33.3% of $300
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.KyznShareTooLow.selector, 3_333, 5_000));
        vault.mint(id, 1e18);
        _deposit(alice, 100e18, 0); // 50%
        _mint(alice, 1e18);
    }

    /// The ceiling counts all synth outstanding: positions, auctions and bad debt.
    function test_mint_respects_the_debt_ceiling() public {
        vault.setDebtCeiling(id, 100e18);
        _deposit(alice, 1_000e18, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtCeilingExceeded.selector, 100.098e18, 100e18));
        vault.mint(id, 99.6e18);
        _mint(alice, 99.5e18); // 99.9975
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtCeilingExceeded.selector, 100.00755e18, 100e18));
        vault.mint(id, 0.01e18);
    }

    function test_paused_mints() public {
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 10e18);
        vm.expectEmit(address(vault));
        emit SiliconVault.MintsPaused(id);
        vault.pauseMints(id);
        assertTrue(_market().mintsPaused);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.MintingPaused.selector, id));
        vault.mint(id, 1e18);

        // Everything else continues.
        _repay(alice, 1e18);
        _deposit(alice, 1e18, 0);
        _withdraw(alice, 1e18, 0);

        vm.expectEmit(address(vault));
        emit SiliconVault.MintsUnpaused(id);
        vault.unpauseMints(id);
        _mint(alice, 1e18);
    }

    /// Mint and withdraw-with-debt use the feed's isFresh(): a price fresh enough to liquidate on
    /// is not fresh enough to borrow against.
    function test_mint_and_withdraw_need_isFresh_not_liquidation_freshness() public {
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 10e18);
        feed.setUpdatedAt(block.timestamp - FEED_MAX_AGE - 1);
        assertFalse(feed.isFresh());
        assertTrue(feed.isFreshForLiquidation());
        vm.startPrank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.mint(id, 1e18);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.withdraw(id, 1e18, 0);
        vm.stopPrank();
    }

    /// The reverse: a feed fresh for minting but not for liquidating does not stop a mint or a
    /// withdrawal.
    function test_mint_and_withdraw_ignore_liquidation_freshness() public {
        _deposit(alice, 1_000e18, 0);
        feed.setFreshForLiquidation(false);
        assertTrue(feed.isFresh());
        _mint(alice, 10e18);
        _withdraw(alice, 1e18, 0);
    }

    /// The vault has the feed record its checked rounds before it reads freshness.
    function test_mint_and_withdraw_sync_the_feed_first() public {
        _deposit(alice, 1_000e18, 0);
        uint256 before = feed.syncs();
        _mint(alice, 10e18);
        assertEq(feed.syncs(), before + 1);
        _withdraw(alice, 1e18, 0);
        assertEq(feed.syncs(), before + 2);
    }

    function test_mint_needs_fresh_prices() public {
        _deposit(alice, 1_000e18, 0);
        vm.warp(block.timestamp + FEED_MAX_AGE + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.StalePrice.selector, address(feed)));
        vault.mint(id, 1e18);

        feed.set(SYNTH_USD);
        _mint(alice, 1e18);
        oracle.setUnavailable(true);
        vm.prank(alice);
        vm.expectRevert(MockKyznOracle.OracleUnavailable.selector);
        vault.mint(id, 1e18);
    }

    /// A price waiting in its dispute window counts for mint and withdraw when it is higher than
    /// the final one, never when it is lower, and never for liquidation. At $2.50 pending, 80
    /// synth ($201 of debt against $300) is 149.2%; 79 (79.395 owed, $198.49) is 151.1%.
    function test_a_higher_pending_price_counts_for_mint_and_withdraw() public {
        _deposit(alice, 300e18, 0);
        feed.setPending(2.5e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, 14_925, 15_000));
        vault.mint(id, 80e18);
        _mint(alice, 79e18);

        // 297 $KYZN left: 149.6% at $2.50 pending, 187% at the final $2.00.
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, 14_963, 15_000));
        vault.withdraw(id, 3e18, 0);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.NotLiquidatable.selector, 18_892, 15_000));
        vault.startAuction(alice, id);

        feed.setPending(1e18); // lower: the final $2.00 governs
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, 14_985, 15_000));
        vault.mint(id, 20.6e18); // 100.098 owed, $200.20
    }

    /// The synth price moves the debt value: at $2.50 the same mint needs more collateral.
    function test_synth_price_moves_the_requirement() public {
        _deposit(alice, 300e18, 0);
        feed.set(2.5e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.CollateralRatioTooLow.selector, 14_925, 15_000));
        vault.mint(id, 80e18); // 80.4 x $2.50 = $201
        _mint(alice, 79e18);
    }

    function test_zero_mint_fee_mints_nothing_to_the_router() public {
        vault.setMintFee(id, 0);
        _deposit(alice, 300e18, 0);
        _mint(alice, 10e18);
        assertEq(synth.balanceOf(feeRouter), 0);
        assertEq(vault.debtOf(id, alice), 10e18);
    }

    // ================================================================ repay

    function test_repay_part_then_all() public {
        _deposit(alice, 300e18, 0);
        _mint(alice, 90e18); // debt 90.45

        vm.expectEmit(address(vault));
        emit SiliconVault.Repaid(id, alice, 40e18);
        assertEq(_repay(alice, 40e18), 40e18);
        assertEq(vault.debtOf(id, alice), 50.45e18);
        assertEq(synth.balanceOf(alice), 50e18);
        _assertSupplyIsDebt();

        // The rest needs the mint fee's 0.45 too: alice buys it back from the router.
        vm.prank(feeRouter);
        assertTrue(synth.transfer(alice, 0.45e18));
        assertEq(_repay(alice, type(uint256).max), 50.45e18, "an amount above the debt repays it all");
        (uint256 k,, uint256 shares) = _position(alice);
        assertEq(shares, 0);
        assertEq(synth.totalSupply(), 0);
        SiliconVault.Market memory m = _market();
        assertEq(m.totalDebt, 0);
        assertEq(m.totalShares, 0);

        oracle.setUnavailable(true);
        _withdraw(alice, k, 0);
    }

    function test_repay_rules() public {
        vm.startPrank(alice);
        vm.expectRevert(SiliconVault.ZeroAmount.selector);
        vault.repay(id, 0);
        vm.expectRevert(SiliconVault.NoDebt.selector);
        vault.repay(id, 1);
        vm.stopPrank();
    }

    /// Repay reads no price: it works with the feed stale and the oracle down.
    function test_repay_always_works() public {
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 10e18);
        feed.setUpdatedAt(block.timestamp - FEED_MAX_AGE - 1);
        oracle.setUnavailable(true);
        _repay(alice, 5e18);
        assertEq(vault.debtOf(id, alice), 5.05e18);
    }

    function test_repay_above_balance_reverts_in_the_synth() public {
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 10e18);
        vm.prank(alice);
        assertTrue(synth.transfer(bob, 10e18));
        vm.prank(alice);
        vm.expectRevert();
        vault.repay(id, 1e18);
    }

    // ================================================================ minimum debt

    /// The minimum debt is a per-market setting, bit 512: a fresh market reports it unset, and
    /// openMarket reverts with it until the owner sets it.
    function test_a_market_needs_a_minimum_debt() public {
        assertEq(vault.SETTING_MIN_DEBT(), 512);
        assertEq(vault.ALL_SETTINGS(), 1023);

        SiliconVault v = new SiliconVault(IERC20(address(kyzn)), IERC20(address(usdg)), IKyznUsdOracle(address(oracle)));
        SiliconSynth s = new SiliconSynth("Kyzen Network H100-HR", "kH100", address(v));
        uint256 m = v.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(feed)));
        assertTrue(v.unsetSettings(m) & 512 != 0, "bit 512 unset on a fresh market");

        v.setMintFee(m, MINT_FEE_BPS);
        v.setBorrowFee(m, BORROW_FEE_BPS);
        v.setLiquidationPenalty(m, PENALTY_BPS);
        v.setDebtCeiling(m, CEILING);
        v.setAuctionDuration(AUCTION_DURATION);
        v.setAuctionStartPremium(START_PREMIUM_BPS);
        v.setAuctionFloor(AUCTION_FLOOR_BPS);
        v.setFeeRouter(feeRouter);
        assertEq(v.unsetSettings(m), 512, "only the minimum debt is left");
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.SettingsUnset.selector, m, uint16(512)));
        v.openMarket(m);

        v.setMinDebt(m, MIN_DEBT);
        assertEq(v.unsetSettings(m) & 512, 0, "bit 512 cleared");
        assertEq(v.unsetSettings(m), 0);
        v.openMarket(m);
        assertTrue(v.market(m).open);
    }

    /// The minimum is per market: a second market keeps its own, and setting one leaves the other.
    function test_the_minimum_debt_is_per_market() public {
        (uint256 m,) = _freshMarket();
        vault.setMinDebt(id, 7e18);
        vault.setMinDebt(m, 9e18);
        assertEq(_market().minDebt, 7e18);
        assertEq(vault.market(m).minDebt, 9e18);
        assertEq(vault.market(m).settings & 512, 512);
    }

    /// A mint may not leave debt between zero and the minimum: 99 synth plus its 0.495 fee is
    /// 99.495 owed, short of 100.
    function test_a_mint_leaving_debt_below_the_minimum_reverts() public {
        vault.setMinDebt(id, 100e18);
        _deposit(alice, 1_000e18, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtBelowMinimum.selector, 99.495e18, 100e18));
        vault.mint(id, 99e18);
        (,, uint256 shares) = _position(alice);
        assertEq(shares, 0, "nothing was minted");
        assertEq(synth.totalSupply(), 0);

        _mint(alice, 100e18); // 100.5 owed
        assertEq(vault.debtOf(id, alice), 100.5e18);
    }

    /// A mint that reaches the minimum exactly passes; a wei of synth less does not. 100 synth and
    /// its 0.5 fee are 100.5 owed; 100 synth less a wei pays the same 0.5 fee (rounded up), so it
    /// owes 100.5 less a wei.
    function test_a_mint_reaching_exactly_the_minimum_passes() public {
        vault.setMinDebt(id, 100.5e18);
        _deposit(alice, 1_000e18, 0);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtBelowMinimum.selector, 100.5e18 - 1, 100.5e18));
        vault.mint(id, 100e18 - 1);
        _mint(alice, 100e18);
        assertEq(vault.debtOf(id, alice), 100.5e18);
        _assertSupplyIsDebt();
    }

    /// A position under a raised minimum may mint a little, as long as the mint carries it to the
    /// minimum. 10.05 owed under a minimum of 11: a mint of 0.5 (0.5025 with its fee) leaves
    /// 10.5525 and is refused; 0.95 (0.95475 with its fee) reaches 11.00475 and passes.
    function test_a_position_under_a_raised_minimum_mints_a_little() public {
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 10e18); // 10.05 owed
        vault.setMinDebt(id, 11e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtBelowMinimum.selector, 10.5525e18, 11e18));
        vault.mint(id, 0.5e18);
        _mint(alice, 0.95e18);
        assertEq(vault.debtOf(id, alice), 11.00475e18);
        _assertSupplyIsDebt();
    }

    /// A mint is judged on the position's whole debt, not on the amount minted: a position above
    /// the minimum may mint any amount, and one below it needs the mint to carry it over.
    function test_a_later_mint_on_a_position_above_the_minimum_works() public {
        vault.setMinDebt(id, 100e18);
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 100e18); // 100.5 owed, above the minimum
        _mint(alice, 1); // a mint far below the minimum is fine on top of it
        _mint(alice, 5e18);
        assertGt(vault.debtOf(id, alice), 105.5e18);
        _assertSupplyIsDebt();
    }

    /// A partial repay may not leave debt between zero and the minimum. 100 synth owed 100.5, a
    /// minimum of 50: repaying 50.5 leaves exactly 50, a wei more leaves less.
    function test_a_partial_repay_leaving_debt_below_the_minimum_reverts() public {
        vault.setMinDebt(id, 50e18);
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 100e18); // 100.5 owed

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtBelowMinimum.selector, 49.9e18, 50e18));
        vault.repay(id, 50.6e18);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtBelowMinimum.selector, 50e18 - 1, 50e18));
        vault.repay(id, 50.5e18 + 1);
        assertEq(vault.debtOf(id, alice), 100.5e18, "the reverted repays burned nothing");
        assertEq(synth.balanceOf(alice), 100e18);

        assertEq(_repay(alice, 50.5e18), 50.5e18); // leaves exactly the minimum
        assertEq(vault.debtOf(id, alice), 50e18);
        _assertSupplyIsDebt();
    }

    /// A repay in full always passes, whatever the minimum: the amount may be the debt exactly or
    /// anything above it.
    function test_a_full_repay_passes() public {
        vault.setMinDebt(id, 50e18);
        _deposit(alice, 1_000e18, 0);
        _deposit(bob, 1_000e18, 0);
        _mint(alice, 100e18);
        _mint(bob, 100e18);
        vm.startPrank(feeRouter);
        assertTrue(synth.transfer(alice, 0.5e18)); // the mint fee, to cover the whole debt
        assertTrue(synth.transfer(bob, 0.5e18));
        vm.stopPrank();

        assertEq(_repay(alice, 100.5e18), 100.5e18, "exactly the debt");
        assertEq(_repay(bob, type(uint256).max), 100.5e18, "above the debt");
        (,, uint256 aliceShares) = _position(alice);
        (,, uint256 bobShares) = _position(bob);
        assertEq(aliceShares + bobShares, 0);
        assertEq(synth.totalSupply(), 0);
    }

    /// Raising the minimum later traps no one: a position under the new minimum can still repay in
    /// full, withdraw what its health allows, or mint up over the minimum; only a part payment
    /// that leaves it under is refused.
    function test_raising_the_minimum_traps_no_one() public {
        _deposit(alice, 1_000e18, 0);
        _deposit(bob, 1_000e18, 0);
        _mint(alice, 10e18); // 10.05 owed, far above the 1 wei minimum
        vault.setMinDebt(id, 100e18);

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtBelowMinimum.selector, 5.05e18, 100e18));
        vault.repay(id, 5e18);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtBelowMinimum.selector, 5.025e18, 100e18));
        vault.mint(id, 5e18); // a new position starts at the new minimum

        _withdraw(alice, 1e18, 0); // still healthy: collateral is not held back by the minimum
        _mint(alice, 95e18); // carried over the minimum: 10.05 + 95.475 = 105.525 owed
        assertEq(vault.debtOf(id, alice), 105.525e18);

        // And back down: the way out is a full repay.
        uint256 debt = vault.debtOf(id, alice);
        uint256 gap = debt - synth.balanceOf(alice); // the fees, which the router holds
        vm.prank(feeRouter);
        assertTrue(synth.transfer(alice, gap));
        assertEq(_repay(alice, type(uint256).max), debt);
        (,, uint256 shares) = _position(alice);
        assertEq(shares, 0);
    }

    /// A position below a raised minimum can always repay in full: nothing else is needed.
    function test_a_position_under_a_raised_minimum_repays_in_full() public {
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 10e18);
        vault.setMinDebt(id, 1_000_000e18);
        vm.prank(feeRouter);
        assertTrue(synth.transfer(alice, 0.05e18));
        assertEq(_repay(alice, vault.debtOf(id, alice)), 10.05e18);
        (,, uint256 shares) = _position(alice);
        assertEq(shares, 0);
        assertEq(synth.totalSupply(), 0);
    }

    /// Repay still reads no price with a minimum set: with the feed stale and the oracle down, a
    /// repay is refused only by the minimum, never by a price, and a full repay works.
    function test_repay_with_a_minimum_reads_no_price() public {
        vault.setMinDebt(id, 5e18);
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 10e18); // 10.05 owed
        feed.setUpdatedAt(block.timestamp - FEED_MAX_AGE - 1);
        oracle.setUnavailable(true);
        uint256 updates = oracle.updates();
        uint256 syncs = feed.syncs();

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtBelowMinimum.selector, 3.05e18, 5e18));
        vault.repay(id, 7e18);
        _repay(alice, 5e18); // 5.05 left
        assertEq(vault.debtOf(id, alice), 5.05e18);
        vm.prank(feeRouter);
        assertTrue(synth.transfer(alice, 0.05e18));
        _repay(alice, type(uint256).max);
        (,, uint256 shares) = _position(alice);
        assertEq(shares, 0);
        assertEq(oracle.updates(), updates);
        assertEq(feed.syncs(), syncs);
    }

    /// The rule is strict: debt is judged rounded down. With the rate index at 1.05 a mint of 10
    /// wei buys 10 shares worth 10.5 wei, which rounds down to 10: a minimum of 11 refuses it,
    /// though the true debt (rounded up it is 11) is not below it.
    function test_the_minimum_is_judged_on_debt_rounded_down() public {
        vault.setMintFee(id, 0); // the borrow fee is the fixture's 5% a year
        _deposit(alice, 1_000e18, 0);
        _deposit(bob, 1_000e18, 0);
        _mint(alice, 100e18);
        _warp(365 days);
        vault.drip(id); // 100 shares owe 105: 1.05 a share
        vault.setMinDebt(id, 11);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.DebtBelowMinimum.selector, 10, 11));
        vault.mint(id, 10);
        vault.setMinDebt(id, 10);
        _mint(bob, 10);
        (,, uint256 shares) = _position(bob);
        assertEq(shares, 10);
        assertEq(vault.debtOf(id, bob), 10);
    }

    // ================================================================ borrow fee

    /// 100.5 synth of debt for a year at 5%: 5.025 synth of fee to the router.
    function test_borrow_fee_accrues_per_second() public {
        _deposit(alice, 1_000e18, 0);
        _mint(alice, 100e18);
        uint256 routerBefore = synth.balanceOf(feeRouter); // the 0.5 mint fee

        vm.warp(block.timestamp + 365 days);
        assertEq(vault.debtOf(id, alice), 105.525e18, "the view includes the fee not yet dripped");
        vm.expectEmit(address(vault));
        emit SiliconVault.FeesAccrued(id, 5.025e18);
        vm.prank(bob); // anyone
        vault.drip(id);
        assertEq(synth.balanceOf(feeRouter) - routerBefore, 5.025e18);
        assertEq(vault.debtOf(id, alice), 105.525e18);
        assertEq(_market().lastDrip, block.timestamp);
        _assertSupplyIsDebt();

        // One second later: 105.525 x 5% / 31,536,000.
        vm.warp(block.timestamp + 1);
        vault.drip(id);
        assertEq(synth.balanceOf(feeRouter) - routerBefore, 5.025e18 + uint256(105.525e18) * 500 / 10_000 / 365 days);
    }

    function test_drip_without_debt_mints_nothing() public {
        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        vault.drip(id);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(synth.totalSupply(), 0);
    }

    /// A borrow-fee change applies from the moment it takes effect: the old rate is dripped first.
    /// On the open market it is queued a day before the year is out and applied at its end.
    function test_borrow_fee_change_drips_at_the_old_rate() public {
        _deposit(alice, 1_000e18, 0);
        vault.setMintFee(id, 0);
        _mint(alice, 100e18);
        vm.warp(block.timestamp + 365 days - 1 days);
        vault.setBorrowFee(id, 1_000);
        assertEq(synth.balanceOf(feeRouter), 0, "queueing drips nothing");
        vm.warp(block.timestamp + 1 days);
        vault.applySetting(vault.SETTING_BORROW_FEE(), id);
        assertEq(synth.balanceOf(feeRouter), 5e18);
        vm.warp(block.timestamp + 365 days);
        vault.drip(id);
        assertEq(synth.balanceOf(feeRouter), 5e18 + 10.5e18);
    }

    /// Debt shares: a later borrower's shares buy the debt per share of its time, and each
    /// position's debt grows by the same rate.
    function test_positions_share_the_rate_index() public {
        vault.setMintFee(id, 0);
        _deposit(alice, 1_000e18, 0);
        _deposit(bob, 1_000e18, 0);
        _mint(alice, 100e18);
        _warp(365 days);
        _mint(bob, 100e18);
        // Bob's shares round up, so a wei of debt per share moves to him: rounding never favours
        // the borrower who mints.
        assertApproxEqAbs(vault.debtOf(id, alice), 105e18, 1);
        assertEq(vault.debtOf(id, bob), 100e18);
        (,, uint256 aliceShares) = _position(alice);
        (,, uint256 bobShares) = _position(bob);
        assertEq(bobShares, uint256(100e18) * 100e18 / 105e18 + 1);
        assertEq(aliceShares, 100e18);

        _warp(365 days);
        vault.drip(id);
        assertApproxEqAbs(vault.debtOf(id, alice), 110.25e18, 1);
        assertApproxEqAbs(vault.debtOf(id, bob), 105e18, 1);
        SiliconVault.Market memory m = _market();
        assertApproxEqAbs(vault.debtOf(id, alice) + vault.debtOf(id, bob), m.totalDebt, 2);
        assertLe(vault.debtOf(id, alice) + vault.debtOf(id, bob), m.totalDebt);
        _assertSupplyIsDebt();
    }

    /// Everyone can close: the last position to repay pays exactly what is left.
    function test_every_position_can_close() public {
        _deposit(alice, 1_000e18, 0);
        _deposit(bob, 1_000e18, 0);
        _deposit(carol, 1_000e18, 0);
        _mint(alice, 33.333333333333333333e18);
        _warp(17 days + 3);
        _mint(bob, 7.777777777777777777e18);
        _warp(91 days + 11);
        _mint(carol, 1);
        _warp(200 days);
        vault.drip(id); // every fee is now synth at the router
        address[3] memory who = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            uint256 debt = vault.debtOf(id, who[i]);
            uint256 held = synth.balanceOf(who[i]);
            if (debt > held) {
                vm.prank(feeRouter);
                assertTrue(synth.transfer(who[i], debt - held));
            }
            _repay(who[i], type(uint256).max);
            (,, uint256 shares) = _position(who[i]);
            assertEq(shares, 0);
            _assertSupplyIsDebt();
        }
        SiliconVault.Market memory m = _market();
        assertEq(m.totalDebt, 0);
        assertEq(m.totalShares, 0);
    }

    // ================================================================ views

    function test_health_view() public {
        _deposit(alice, 200e18, 100 * USDG_UNIT);
        _mint(alice, 50e18); // debt 50.25 = $100.50
        (uint256 collateralValue, uint256 debtValue, uint256 ratioBps, uint256 kyznShareBps) = vault.health(id, alice);
        assertEq(collateralValue, 300e18);
        assertEq(debtValue, 100.5e18);
        assertEq(ratioBps, 29_850);
        assertEq(kyznShareBps, 6_666);

        (,, ratioBps,) = vault.health(id, bob);
        assertEq(ratioBps, type(uint256).max, "no debt");
    }

    // ================================================================ reentrancy

    /// A collateral token that calls back into the vault mid-withdrawal is stopped by the guard.
    function test_withdrawal_cannot_be_reentered() public {
        CallbackToken hook = new CallbackToken();
        SiliconVault v = new SiliconVault(IERC20(address(kyzn)), IERC20(address(hook)), IKyznUsdOracle(address(oracle)));
        SiliconSynth s = new SiliconSynth("Kyzen Network H100-HR", "kH100", address(v));
        uint256 m = v.addMarket(ISiliconSynth(address(s)), ISiliconFeed(address(feed)));
        v.setAuctionDuration(AUCTION_DURATION);
        v.setAuctionStartPremium(START_PREMIUM_BPS);
        v.setAuctionFloor(AUCTION_FLOOR_BPS);
        v.setFeeRouter(feeRouter);
        v.setMintFee(m, MINT_FEE_BPS);
        v.setBorrowFee(m, BORROW_FEE_BPS);
        v.setLiquidationPenalty(m, PENALTY_BPS);
        v.setDebtCeiling(m, CEILING);
        v.setMinDebt(m, MIN_DEBT);
        v.openMarket(m);

        hook.mint(alice, 100e6);
        vm.startPrank(alice);
        hook.approve(address(v), type(uint256).max);
        v.deposit(m, 0, 100e6);
        hook.arm(address(v), abi.encodeCall(SiliconVault.withdraw, (m, 0, 50e6)));
        v.withdraw(m, 0, 50e6);
        vm.stopPrank();

        assertTrue(hook.callbackReverted());
        assertEq(hook.callbackError(), abi.encodeWithSelector(ReentrancyGuard.ReentrancyGuardReentrantCall.selector));
        (, uint256 left,) = v.positions(m, alice);
        assertEq(left, 50e6, "only the outer withdrawal happened");
        assertEq(hook.balanceOf(address(v)), 50e6);
    }
}
