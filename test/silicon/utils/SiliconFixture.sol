// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SiliconVault} from "../../../src/silicon/SiliconVault.sol";
import {SiliconSynth} from "../../../src/silicon/SiliconSynth.sol";
import {ISiliconSynth} from "../../../src/silicon/interfaces/ISiliconSynth.sol";
import {ISiliconFeed} from "../../../src/silicon/interfaces/ISiliconFeed.sol";
import {IKyznUsdOracle} from "../../../src/silicon/interfaces/IKyznUsdOracle.sol";
import {MockToken, MockKyznOracle, MockSiliconFeed} from "../mocks/SiliconMocks.sol";

/// One open H100-HR market on a SiliconVault, with $KYZN and USDG (6 decimals) stand-ins, a
/// settable $KYZN oracle and a settable synth feed. The test contract owns the vault.
///
/// The levels below are test values only: SPEC 3.5 leaves every level open until Gen 2.
/// Prices: $KYZN $1.00, the synth $2.00.
abstract contract SiliconFixture is Test {
    uint256 internal constant START = 1_790_604_000; // Monday 28 September 2026, 14:00 UTC

    uint256 internal constant MINT_FEE_BPS = 50; // 0.5%
    uint256 internal constant BORROW_FEE_BPS = 500; // 5% a year
    uint256 internal constant PENALTY_BPS = 1_000; // 10%
    uint256 internal constant CEILING = 1_000_000e18;
    /// 1 wei of synth, the largest minimum the older tests tolerate: they open positions that owe
    /// as little as 1 wei rounded down (the fuzz tests mint 1 wei, test_every_position_can_close
    /// mints 1 wei), and 2 fails two of the fuzz tests. Tests of the minimum set their own.
    uint256 internal constant MIN_DEBT = 1;
    uint256 internal constant AUCTION_DURATION = 6 hours;
    uint256 internal constant START_PREMIUM_BPS = 2_000; // 20%
    uint256 internal constant AUCTION_FLOOR_BPS = 4_000; // 40% of the oracle value
    uint256 internal constant FEED_MAX_AGE = 2 hours;

    uint256 internal constant KYZN_USD = 1e18;
    uint256 internal constant SYNTH_USD = 2e18;
    uint256 internal constant USDG_UNIT = 1e6;

    MockToken internal kyzn;
    MockToken internal usdg;
    MockKyznOracle internal oracle;
    MockSiliconFeed internal feed;
    SiliconSynth internal synth;
    SiliconVault internal vault;
    uint256 internal id;

    address internal feeRouter = makeAddr("feeRouter");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal bidder = makeAddr("bidder");

    function setUp() public virtual {
        vm.warp(START);
        kyzn = new MockToken("KYZN", 18);
        usdg = new MockToken("USDG", 6);
        oracle = new MockKyznOracle(KYZN_USD);
        feed = new MockSiliconFeed(SYNTH_USD, FEED_MAX_AGE);
        vault = new SiliconVault(IERC20(address(kyzn)), IERC20(address(usdg)), IKyznUsdOracle(address(oracle)));
        synth = new SiliconSynth("Kyzen Network H100-HR", "kH100", address(vault));
        id = vault.addMarket(ISiliconSynth(address(synth)), ISiliconFeed(address(feed)));
        _configureVault();
        _configureMarket(id);
        feed.setReady(true);
        vault.openMarket(id);

        address[4] memory users = [alice, bob, carol, bidder];
        for (uint256 i; i < users.length; ++i) {
            kyzn.mint(users[i], 10_000_000e18);
            usdg.mint(users[i], 10_000_000 * USDG_UNIT);
            vm.startPrank(users[i]);
            kyzn.approve(address(vault), type(uint256).max);
            usdg.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _configureVault() internal {
        vault.setAuctionDuration(AUCTION_DURATION);
        vault.setAuctionStartPremium(START_PREMIUM_BPS);
        vault.setAuctionFloor(AUCTION_FLOOR_BPS);
        vault.setFeeRouter(feeRouter);
    }

    function _configureMarket(uint256 marketId) internal {
        vault.setMintFee(marketId, MINT_FEE_BPS);
        vault.setBorrowFee(marketId, BORROW_FEE_BPS);
        vault.setLiquidationPenalty(marketId, PENALTY_BPS);
        vault.setDebtCeiling(marketId, CEILING);
        vault.setMinDebt(marketId, MIN_DEBT);
    }

    // ---------------------------------------------------------------- actions

    function _deposit(address who, uint256 kyznAmount, uint256 usdgAmount) internal {
        vm.prank(who);
        vault.deposit(id, kyznAmount, usdgAmount);
    }

    function _mint(address who, uint256 amount) internal {
        vm.prank(who);
        vault.mint(id, amount);
    }

    function _repay(address who, uint256 amount) internal returns (uint256) {
        vm.prank(who);
        return vault.repay(id, amount);
    }

    function _withdraw(address who, uint256 kyznAmount, uint256 usdgAmount) internal {
        vm.prank(who);
        vault.withdraw(id, kyznAmount, usdgAmount);
    }

    /// Moves the clock and re-posts the synth price, so it stays fresh.
    function _warp(uint256 seconds_) internal {
        vm.warp(block.timestamp + seconds_);
        feed.set(feed.price());
    }

    /// Waits out the 24 hours a setting queued on the open market needs (the synth price re-posted)
    /// and applies it. `marketId` is 0 for a vault-wide setting.
    function _applyQueued(uint16 setting, uint256 marketId) internal {
        _warp(vault.SETTING_DELAY());
        vault.applySetting(setting, marketId);
    }

    // ---------------------------------------------------------------- reads

    function _position(address who) internal view returns (uint256 k, uint256 u, uint256 shares) {
        return vault.positions(id, who);
    }

    function _market() internal view returns (SiliconVault.Market memory) {
        return vault.market(id);
    }

    /// The mint fee a mint of `amount` pays, rounded up as the vault rounds it.
    function _fee(uint256 amount) internal pure returns (uint256) {
        return Math.mulDiv(amount, MINT_FEE_BPS, 10_000, Math.Rounding.Ceil);
    }

    /// Synth supply equals the market's total debt: positions, auctions and bad debt.
    function _assertSupplyIsDebt() internal view {
        SiliconVault.Market memory m = _market();
        assertEq(synth.totalSupply(), m.totalDebt + m.auctionDebt + m.badDebt, "supply != debt");
    }
}
