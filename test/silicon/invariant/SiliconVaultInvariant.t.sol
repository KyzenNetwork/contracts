// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SiliconVault} from "../../../src/silicon/SiliconVault.sol";
import {SiliconSynth} from "../../../src/silicon/SiliconSynth.sol";
import {MockToken, MockKyznOracle, MockSiliconFeed} from "../mocks/SiliconMocks.sol";
import {SiliconFixture} from "../utils/SiliconFixture.sol";
import {DUST} from "../utils/MinDebtDust.sol";

/// Random deposits, withdrawals, mints, repayments, drips, price moves, time, auctions, bids,
/// closes and bad-debt covers on one market, by four accounts. After every action it checks that
/// each account owes nothing or at least the market's minimum debt, exactly for the account that
/// minted or repaid, less DUST for the others (an account in an auction owes nothing: the auction
/// holds its debt).
contract VaultHandler is Test {
    uint256 internal constant ACTORS = 4;

    SiliconVault internal vault;
    SiliconSynth internal synth;
    MockToken internal kyzn;
    MockToken internal usdg;
    MockKyznOracle internal oracle;
    MockSiliconFeed internal feed;
    address internal feeRouter;
    uint256 internal id;
    address[ACTORS] internal actors;

    uint256[] public auctionIds;
    mapping(uint256 => uint256) public startKyzn;
    mapping(uint256 => uint256) public startUsdg;
    /// Collateral each auction has paid out: to bidders, back to the position, to the fee router.
    mapping(uint256 => uint256) public outKyzn;
    mapping(uint256 => uint256) public outUsdg;

    bool public withdrawLeftUnhealthy;
    bool public auctionOverpaid;
    bool public routerSynthDecreased;
    bool public dripLoweredDebt;
    /// An end that was not the first with debt left failed to close, or a restart changed what
    /// the auction holds or owes, or its terms.
    bool public closeBrokeRestartRule;
    /// closeAuction reverted after the end. Here the feed is always fresh for liquidation, the
    /// oracle always prices and the synth price is never zero, so neither a restart nor a close
    /// has a reason to.
    bool public closeReverted;
    /// After some action an account owed above zero and below the minimum debt less DUST.
    bool public minDebtBroken;
    /// After its own successful mint or repay an account owed above zero and below the minimum
    /// debt (no DUST: the vault checks exactly this).
    bool public actingMinDebtBroken;
    uint256 internal lastRouterSynth;
    /// The market's minimum debt, which the handler never changes.
    uint256 public minDebt;

    uint256 public withdrawsWithDebt;
    uint256 public mints;
    uint256 public auctionsStarted;
    uint256 public bids;
    uint256 public closes;
    uint256 public restarts;
    /// Mints and part payments the vault refused with DebtBelowMinimum.
    uint256 public minDebtRefusals;

    /// Every action ends by checking the minimum debt, whichever way it returns.
    modifier checked() {
        _;
        _checkMinDebt();
    }

    constructor(
        SiliconVault vault_,
        SiliconSynth synth_,
        MockToken kyzn_,
        MockToken usdg_,
        MockKyznOracle oracle_,
        MockSiliconFeed feed_,
        address feeRouter_,
        uint256 id_
    ) {
        vault = vault_;
        synth = synth_;
        kyzn = kyzn_;
        usdg = usdg_;
        oracle = oracle_;
        feed = feed_;
        feeRouter = feeRouter_;
        id = id_;
        minDebt = vault_.market(id_).minDebt;
        for (uint256 i; i < ACTORS; ++i) {
            actors[i] = makeAddr(string.concat("actor", vm.toString(i)));
            kyzn.mint(actors[i], 1e30);
            usdg.mint(actors[i], 1e18);
            vm.startPrank(actors[i]);
            kyzn.approve(address(vault), type(uint256).max);
            usdg.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function auctionCount() external view returns (uint256) {
        return auctionIds.length;
    }

    // ---------------------------------------------------------------- positions

    /// $KYZN with at most as much USDG in value at $1.00, so the 50% rule usually holds.
    function deposit(uint256 who, uint256 k, uint256 u) external checked {
        k = bound(k, 0, 1_000_000e18);
        u = bound(u, 0, k / 1e12);
        if (k == 0 && u == 0) return;
        vm.prank(actors[who % ACTORS]);
        vault.deposit(id, k, u);
    }

    /// Up to 30% of each collateral, so a position with debt often has the room for it.
    function withdraw(uint256 who, uint256 k, uint256 u) external checked {
        address a = actors[who % ACTORS];
        (uint256 heldK, uint256 heldU, uint256 shares) = vault.positions(id, a);
        k = heldK * (k % 31) / 100;
        u = heldU * (u % 31) / 100;
        if (k == 0 && u == 0) return;
        vm.prank(a);
        try vault.withdraw(id, k, u) {
            if (shares != 0) {
                ++withdrawsWithDebt;
                (,, uint256 ratioBps, uint256 shareBps) = vault.health(id, a);
                if (ratioBps < 15_000 || shareBps < 5_000) withdrawLeftUnhealthy = true;
            }
        } catch {}
    }

    /// Up to the room the position has at current prices (with the fee), so most mints succeed;
    /// one in eight asks for more than the room, and one in eight for a small amount, around
    /// the minimum debt.
    function mint(uint256 who, uint256 amount) external checked {
        address a = actors[who % ACTORS];
        (, uint256 debtValue,, uint256 shareBps) = vault.health(id, a);
        if (shareBps < 6_000) {
            // Top up $KYZN first, so the 50% rule is not what stops every mint.
            uint256 topUp = 100_000e18 + debtValue * 2e18 / oracle.usdPerKyzn();
            kyzn.mint(a, topUp);
            vm.prank(a);
            vault.deposit(id, topUp, 0);
        }
        (uint256 collateralValue,,,) = vault.health(id, a);
        uint256 roomValue = collateralValue * 10_000 / 15_000;
        // The vault prices a mint at the higher of the final and the pending synth price.
        (uint256 synthPrice,) = feed.latestPrice();
        synthPrice = Math.max(synthPrice, feed.pending());
        debtValue = Math.mulDiv(vault.debtOf(id, a), synthPrice, 1e18, Math.Rounding.Ceil);
        if (roomValue <= debtValue) return;
        uint256 room = (roomValue - debtValue) * 1e18 / synthPrice * 1_000 / 1_006;
        if (room == 0) return;
        if (amount % 8 == 0) {
            amount = room + bound(amount, 1, 1e18);
        } else if (amount % 8 == 1) {
            amount = bound(amount, 1, Math.min(room, 2 * minDebt));
        } else {
            amount = bound(amount, 1, room);
        }
        vm.prank(a);
        try vault.mint(id, amount) {
            ++mints;
            _checkActing(a);
        } catch (bytes memory err) {
            _countRefusal(err);
        }
        _checkRouter();
    }

    /// Any amount up to the balance; one in four pays all but a little (up to twice the minimum
    /// debt; in a quarter of those, the minimum or a wei under it, the edge where rounding
    /// decides), so the part payments often land around the minimum.
    function repay(uint256 who, uint256 amount) external checked {
        address a = actors[who % ACTORS];
        uint256 balance = synth.balanceOf(a);
        if (balance == 0) return;
        if (amount % 4 == 0) {
            uint256 debt = vault.debtOf(id, a);
            uint256 left = amount % 16 == 0 ? minDebt - (amount >> 4) % 2 : bound(amount / 4, 0, 2 * minDebt);
            amount = debt > left ? debt - left : 1;
            if (amount > balance) amount = balance;
        } else {
            amount = bound(amount, 1, balance);
        }
        vm.prank(a);
        try vault.repay(id, amount) {
            _checkActing(a);
        } catch (bytes memory err) {
            _countRefusal(err);
        }
        _checkRouter();
    }

    /// Synth changes hands, so the accounts that repay or bid are not only those that minted.
    function transfer(uint256 from, uint256 to, uint256 amount) external checked {
        address a = actors[from % ACTORS];
        uint256 balance = synth.balanceOf(a);
        if (balance == 0) return;
        vm.prank(a);
        require(synth.transfer(actors[to % ACTORS], bound(amount, 1, balance)), "transfer");
    }

    function drip() external checked {
        uint256 before = vault.market(id).totalDebt;
        vault.drip(id);
        if (vault.market(id).totalDebt < before) dripLoweredDebt = true;
        _checkRouter();
    }

    // ---------------------------------------------------------------- prices and time

    /// Time passes and the reporter posts again (staleness has its own unit tests).
    function warp(uint256 seconds_) external checked {
        vm.warp(block.timestamp + bound(seconds_, 1, 2 days));
        feed.set(feed.price());
    }

    /// $KYZN moves by -60% to +40%, between $0.01 and $100.
    function moveKyzn(uint256 move) external checked {
        uint256 next = oracle.usdPerKyzn() * bound(move, 40, 140) / 100;
        if (next < 0.01e18) next = 0.01e18;
        if (next > 100e18) next = 100e18;
        oracle.set(next);
    }

    /// The synth moves by -30% to +60%, between $0.10 and $50.
    function moveSynth(uint256 move) external checked {
        uint256 next = feed.price() * bound(move, 70, 160) / 100;
        if (next < 0.1e18) next = 0.1e18;
        if (next > 50e18) next = 50e18;
        feed.set(next);
    }

    /// A price posted and waiting in its dispute window, from half to twice the final one, or
    /// none. It counts for mints and withdrawals only when higher.
    function movePending(uint256 move) external checked {
        feed.setPending(move % 3 == 0 ? 0 : feed.price() * bound(move, 50, 200) / 100);
    }

    // ---------------------------------------------------------------- auctions

    function startAuction(uint256 who, uint256 caller) external checked {
        vm.prank(actors[caller % ACTORS]);
        try vault.startAuction(actors[who % ACTORS], id) returns (uint256 auctionId) {
            SiliconVault.Auction memory a = vault.auction(auctionId);
            auctionIds.push(auctionId);
            startKyzn[auctionId] = a.kyzn;
            startUsdg[auctionId] = a.usdg;
            ++auctionsStarted;
        } catch {}
        _checkRouter();
    }

    function bid(uint256 who, uint256 index, uint256 maxSynth) external checked {
        if (auctionIds.length == 0) return;
        uint256 auctionId = auctionIds[index % auctionIds.length];
        SiliconVault.Auction memory before = vault.auction(auctionId);
        if (before.account == address(0)) return;
        address a = actors[who % ACTORS];
        uint256 balance = synth.balanceOf(a);
        if (balance == 0) return;
        vm.prank(a);
        try vault.bid(auctionId, bound(maxSynth, 1, balance)) returns (uint256, uint256 k, uint256 u) {
            ++bids;
            if (k > before.kyzn || u > before.usdg) auctionOverpaid = true;
            outKyzn[auctionId] += k;
            outUsdg[auctionId] += u;
            // A bid that closes the auction pays what is left to the position or the fee router.
            if (vault.auction(auctionId).account == address(0)) {
                outKyzn[auctionId] += before.kyzn - k;
                outUsdg[auctionId] += before.usdg - u;
                ++closes;
            }
        } catch {}
        _checkRouter();
    }

    /// After the end an auction with debt left restarts once (it stays in place, collateral
    /// untouched); any other end, or the second, closes it and pays out what it held.
    function closeAuction(uint256 index) external checked {
        if (auctionIds.length == 0) return;
        uint256 auctionId = auctionIds[index % auctionIds.length];
        SiliconVault.Auction memory before = vault.auction(auctionId);
        if (before.account == address(0)) return;
        if (block.timestamp < before.startedAt + before.duration) return;
        try vault.closeAuction(auctionId) {}
        catch {
            closeReverted = true;
            return;
        }
        SiliconVault.Auction memory after_ = vault.auction(auctionId);
        bool restartDue = before.debt != 0 && !before.restarted;
        if (restartDue) {
            ++restarts;
            if (after_.account != before.account || !after_.restarted || after_.kyzn != before.kyzn) {
                closeBrokeRestartRule = true;
            }
            if (after_.usdg != before.usdg || after_.debt != before.debt || after_.penalty != before.penalty) {
                closeBrokeRestartRule = true;
            }
            if (after_.startedAt != block.timestamp) closeBrokeRestartRule = true;
            // The restart keeps the terms the auction started with.
            if (after_.duration != before.duration || after_.feeRouter != before.feeRouter) {
                closeBrokeRestartRule = true;
            }
            if (after_.startPremiumBps != before.startPremiumBps || after_.floorBps != before.floorBps) {
                closeBrokeRestartRule = true;
            }
            return;
        }
        if (after_.account != address(0)) closeBrokeRestartRule = true; // a second end must close
        outKyzn[auctionId] += before.kyzn;
        outUsdg[auctionId] += before.usdg;
        ++closes;
    }

    function coverBadDebt(uint256 who, uint256 amount) external checked {
        address a = actors[who % ACTORS];
        uint256 balance = synth.balanceOf(a);
        if (balance == 0 || vault.market(id).badDebt == 0) return;
        vm.prank(a);
        vault.coverBadDebt(id, bound(amount, 1, balance));
    }

    /// Each account owes nothing, or at least the minimum debt rounded down, less DUST. The accrued
    /// borrow fee is included, which only raises a debt.
    function _checkMinDebt() internal {
        for (uint256 i; i < ACTORS; ++i) {
            uint256 debt = vault.debtOf(id, actors[i]);
            (,, uint256 shares) = vault.positions(id, actors[i]);
            if (shares != 0 && debt + DUST < minDebt) minDebtBroken = true;
        }
    }

    /// The account that has just minted or repaid owes nothing, or at least the minimum exactly.
    /// The action dripped, so debtOf is the debt rounded down that the vault judged.
    function _checkActing(address a) internal {
        (,, uint256 shares) = vault.positions(id, a);
        if (shares != 0 && vault.debtOf(id, a) < minDebt) actingMinDebtBroken = true;
    }

    function _countRefusal(bytes memory err) internal {
        if (err.length >= 4 && bytes4(err) == SiliconVault.DebtBelowMinimum.selector) ++minDebtRefusals;
    }

    /// The fee router only ever receives synth here; its balance never falls.
    function _checkRouter() internal {
        uint256 balance = synth.balanceOf(feeRouter);
        if (balance < lastRouterSynth) routerSynthDecreased = true;
        lastRouterSynth = balance;
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 256
/// SPEC Step 7 invariants: a market's synth supply equals its debt (positions, auctions, bad
/// debt); positions' debt shares add up; collateral is all held; no withdrawal leaves a position
/// below 150% or below 50% $KYZN; fees only grow; auctions never pay out more collateral than
/// the position held; every position owes nothing or at least the market's minimum debt.
contract SiliconVaultInvariantTest is SiliconFixture {
    /// 50 synth, so that the handler's small mints and near-full repays often land around it.
    uint256 internal constant INVARIANT_MIN_DEBT = 50e18;

    VaultHandler internal handler;

    function setUp() public override {
        super.setUp();
        vault.setMinDebt(id, INVARIANT_MIN_DEBT);
        handler = new VaultHandler(vault, synth, kyzn, usdg, oracle, feed, feeRouter, id);
        targetContract(address(handler));
    }

    function invariant_supply_equals_debt() public view {
        _assertSupplyIsDebt();
    }

    function invariant_auction_debt_is_the_sum_of_running_auctions() public view {
        uint256 sum;
        for (uint256 i; i < handler.auctionCount(); ++i) {
            sum += vault.auction(handler.auctionIds(i)).debt;
        }
        assertEq(vault.market(id).auctionDebt, sum);
    }

    /// Debt shares add up, positions owe the total to within a wei each (rounding down), and
    /// there are shares exactly when there is debt.
    function invariant_debt_shares_add_up() public view {
        SiliconVault.Market memory m = vault.market(id);
        uint256 shares;
        uint256 owed;
        for (uint256 i; i < 4; ++i) {
            (,, uint256 s) = vault.positions(id, handler.actor(i));
            shares += s;
            if (s != 0) owed += Math.mulDiv(s, m.totalDebt, m.totalShares);
        }
        assertEq(shares, m.totalShares);
        assertEq(m.totalShares == 0, m.totalDebt == 0);
        assertLe(owed, m.totalDebt);
        assertLe(m.totalDebt - owed, 4);
    }

    function invariant_collateral_is_all_held() public view {
        uint256 k;
        uint256 u;
        for (uint256 i; i < 4; ++i) {
            (uint256 pk, uint256 pu,) = vault.positions(id, handler.actor(i));
            k += pk;
            u += pu;
        }
        for (uint256 i; i < handler.auctionCount(); ++i) {
            SiliconVault.Auction memory a = vault.auction(handler.auctionIds(i));
            k += a.kyzn;
            u += a.usdg;
        }
        assertEq(kyzn.balanceOf(address(vault)), k);
        assertEq(usdg.balanceOf(address(vault)), u);
    }

    function invariant_no_withdrawal_leaves_a_position_unhealthy() public view {
        assertFalse(handler.withdrawLeftUnhealthy());
    }

    /// Each auction's payouts so far plus what it still holds equal what the position held.
    function invariant_auctions_never_pay_out_more_than_held() public view {
        assertFalse(handler.auctionOverpaid());
        for (uint256 i; i < handler.auctionCount(); ++i) {
            uint256 auctionId = handler.auctionIds(i);
            SiliconVault.Auction memory a = vault.auction(auctionId);
            assertEq(handler.outKyzn(auctionId) + a.kyzn, handler.startKyzn(auctionId));
            assertEq(handler.outUsdg(auctionId) + a.usdg, handler.startUsdg(auctionId));
        }
    }

    /// An auction restarts at most once: the restart keeps its collateral, debt and penalty, and
    /// every other end closes it. A running auction's price is never below its floor sum, and
    /// its floor never above its start.
    function invariant_an_auction_restarts_at_most_once() public view {
        assertFalse(handler.closeBrokeRestartRule());
        assertFalse(handler.closeReverted(), "a close after the end reverted");
        for (uint256 i; i < handler.auctionCount(); ++i) {
            SiliconVault.Auction memory a = vault.auction(handler.auctionIds(i));
            if (a.account == address(0)) continue;
            assertLe(a.kyznFloorPrice, a.kyznStartPrice);
            assertLe(a.usdgFloorPrice, a.usdgStartPrice);
            uint256 floor = Math.mulDiv(a.kyzn, a.kyznFloorPrice, 1e18, Math.Rounding.Ceil)
                + Math.mulDiv(a.usdg, a.usdgFloorPrice, 1e18, Math.Rounding.Ceil);
            uint256 start = Math.mulDiv(a.kyzn, a.kyznStartPrice, 1e18, Math.Rounding.Ceil)
                + Math.mulDiv(a.usdg, a.usdgStartPrice, 1e18, Math.Rounding.Ceil);
            uint256 price = vault.auctionPrice(handler.auctionIds(i));
            if (price != 0) {
                assertGe(price, floor);
                assertLe(price, start);
            } else {
                assertGe(block.timestamp, a.startedAt + a.duration, "price is zero only once ended");
            }
        }
    }

    /// Every position owes nothing or at least the market's minimum debt (rounded down) less DUST
    /// (see DUST: another account's mint or part repay can lower it by a wei), at the end of every
    /// run and after every action the handler took; the account that has just minted or repaid owes
    /// nothing or the minimum exactly. A position in an auction owes nothing: the auction holds
    /// its debt.
    function invariant_every_position_owes_nothing_or_the_minimum() public view {
        assertFalse(handler.actingMinDebtBroken(), "an account under the minimum after its own action");
        assertFalse(handler.minDebtBroken());
        uint256 minimum = vault.market(id).minDebt;
        assertEq(minimum, INVARIANT_MIN_DEBT);
        for (uint256 i; i < 4; ++i) {
            (,, uint256 shares) = vault.positions(id, handler.actor(i));
            if (shares == 0) continue;
            assertGe(vault.debtOf(id, handler.actor(i)) + DUST, minimum, "a position owes less than the minimum");
        }
    }

    function invariant_fees_only_grow() public view {
        assertFalse(handler.routerSynthDecreased());
        assertFalse(handler.dripLoweredDebt());
    }

    /// What one run did (the log shows the last run). Reach is asserted by the scripted test
    /// below, not here: a run of 256 random calls can miss a path, and a per-run assert would fail
    /// whole campaigns (measured: 15 of 25 campaigns of 64 runs held a run with no mint).
    function afterInvariant() external view {
        console2.log("auctions / bids / closes", handler.auctionsStarted(), handler.bids(), handler.closes());
        console2.log("restarts", handler.restarts());
        console2.log("withdrawals with debt / bad debt", handler.withdrawsWithDebt(), vault.market(id).badDebt);
        console2.log("mints / refused for the minimum debt", handler.mints(), handler.minDebtRefusals());
    }

    // ---------------------------------------------------------------- exercise

    /// The campaign is random; this walks each path once, by hand, so that a handler that stopped
    /// reaching one would fail here instead of passing the campaign without touching it. Prices
    /// are $1.00 for $KYZN and $2.00 for the synth at the start; the minimum debt is 50 synth.
    function test_the_handler_reaches_every_path() public {
        // A deposit and a mint near the room (300 synth: 301.5 owed, $603 against $1,000).
        handler.deposit(0, 1_000e18, 0);
        handler.mint(0, 300e18 + 2); // 2 modulo 8: an amount up to the room, taken as it is
        assertEq(handler.mints(), 1, "a mint");
        _assertInvariants();

        // A second account asks for 9 wei: under the minimum debt, refused.
        handler.deposit(1, 1_000e18, 0);
        handler.mint(1, 9); // 1 modulo 8: a small amount, around the minimum
        assertEq(handler.minDebtRefusals(), 1, "the minimum debt");
        assertEq(handler.mints(), 1);

        // $KYZN falls 60%: the first account is at 66% and its auction starts.
        handler.moveKyzn(40);
        handler.startAuction(0, 1);
        assertEq(handler.auctionsStarted(), 1, "an auction");
        _assertInvariants();

        // A bid takes part of the lot.
        handler.bid(0, 0, 10e18);
        assertEq(handler.bids(), 1, "a bid");

        // The auction ends unsold and restarts, then ends again and closes with bad debt.
        handler.warp(6 hours);
        handler.closeAuction(0);
        assertEq(handler.restarts(), 1, "a restart");
        handler.warp(6 hours);
        handler.closeAuction(0);
        assertEq(handler.closes(), 1, "a close");
        assertGt(vault.market(id).badDebt, 0, "the shortfall is bad debt");
        _assertInvariants();

        // Synth covers part of the bad debt.
        uint256 badDebt = vault.market(id).badDebt;
        handler.coverBadDebt(0, 1e18);
        assertEq(vault.market(id).badDebt, badDebt - 1e18, "bad debt covered");
        _assertInvariants();
    }

    function _assertInvariants() internal view {
        invariant_supply_equals_debt();
        invariant_auction_debt_is_the_sum_of_running_auctions();
        invariant_debt_shares_add_up();
        invariant_collateral_is_all_held();
        invariant_no_withdrawal_leaves_a_position_unhealthy();
        invariant_auctions_never_pay_out_more_than_held();
        invariant_an_auction_restarts_at_most_once();
        invariant_every_position_owes_nothing_or_the_minimum();
        invariant_fees_only_grow();
    }
}
