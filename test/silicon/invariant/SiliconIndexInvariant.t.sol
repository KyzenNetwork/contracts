// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {SiliconVault} from "../../../src/silicon/SiliconVault.sol";
import {SiliconSynth} from "../../../src/silicon/SiliconSynth.sol";
import {StockIndexFeed} from "../../../src/silicon/StockIndexFeed.sol";
import {MarketCalendar} from "../../../src/silicon/MarketCalendar.sol";
import {ISiliconSynth} from "../../../src/silicon/interfaces/ISiliconSynth.sol";
import {ISiliconFeed} from "../../../src/silicon/interfaces/ISiliconFeed.sol";
import {IMarketCalendar} from "../../../src/silicon/interfaces/IMarketCalendar.sol";
import {IKyznUsdOracle} from "../../../src/silicon/interfaces/IKyznUsdOracle.sol";
import {MockToken, MockKyznOracle, MockRoundFeed} from "../mocks/SiliconMocks.sol";
import {DUST} from "../utils/MinDebtDust.sol";

// The levels the owner approved (SPEC 3.5), except the debt ceiling, which is raised so that the
// run is not stopped by it, and the minimum debt, $500 of synth at the index's 100 USD start.
uint256 constant MINT_FEE_BPS = 50;
uint256 constant BORROW_FEE_BPS = 1_200;
uint256 constant PENALTY_BPS = 1_300;
uint256 constant AUCTION_DURATION = 100 minutes;
uint256 constant START_PREMIUM_BPS = 2_000;
uint256 constant FLOOR_BPS = 4_000;
uint256 constant DEBT_CEILING = 100_000e18;
uint256 constant MIN_DEBT = 5e18;

/// Random deposits, withdrawals, mints, repayments, auctions, bids and closes on one market whose
/// price is a real StockIndexFeed over two round feeds and a real MarketCalendar, by four accounts,
/// among time that lands inside the mint window, outside it and over weekends, small moves and
/// jumps of the components, the guardian's clears, sync() and $KYZN price moves.
///
/// The handler keeps a model of the breaker of its own, so that the invariants do not only ask the
/// feed what the feed thinks: a component is latched from the moment a round is posted that moves
/// more than 30% from the round before, until the guardian (this handler) clears the latest round.
contract IndexHandler is Test {
    uint256 internal constant ACTORS = 4;
    uint256 internal constant COMPONENTS = 2;
    /// A component answer (8 decimals) stays between 10 and 3,000 USD.
    uint256 internal constant MIN_ANSWER = 10e8;
    uint256 internal constant MAX_ANSWER = 3_000e8;

    SiliconVault internal vault;
    SiliconSynth internal synth;
    MockToken internal kyzn;
    MockToken internal usdg;
    MockKyznOracle internal oracle;
    StockIndexFeed internal feed;
    MockRoundFeed[COMPONENTS] internal components;
    address internal feeRouter;
    uint256 internal id;
    address[ACTORS] internal actors;

    uint256[] public auctionIds;
    /// Component `i` has been moved by more than 30% in one round and not cleared since.
    mapping(uint256 => bool) public latched;

    /// A mint succeeded although the feed was not fresh or a component's price was over 24 hours old.
    bool public mintNotFresh;
    /// A mint succeeded outside Monday to Friday, 14:30 to 20:00 UTC.
    bool public mintOutsideWindow;
    /// An auction started, or restarted, although the feed was not fresh for liquidation or a
    /// component's price was over 96 hours old.
    bool public liquidationPriceStale;
    /// A mint succeeded while a component was latched.
    bool public mintWhileJumped;
    /// An auction started or restarted while a component was latched.
    bool public auctionWhileJumped;
    /// A new or restarted auction's start or floor price is not the oracle value of the collateral
    /// times (100% + the premium) or the floor share, in synth.
    bool public auctionPricesWrong;
    /// An end that was not the first with debt left failed to close, or a restart changed what the
    /// auction holds or owes, or its terms.
    bool public closeBrokeRestartRule;
    /// closeAuction reverted, after the end, for any reason other than a restart on a stale price.
    bool public closeReverted;
    /// After some action an account owed above zero and below the minimum debt less DUST.
    bool public minDebtBroken;
    /// After its own successful mint or repay an account owed above zero and below the minimum
    /// debt (no DUST: the vault checks exactly this).
    bool public actingMinDebtBroken;

    uint256 public mints;
    /// Mints the vault refused with StalePrice.
    uint256 public mintsStale;
    uint256 public auctionsStarted;
    /// Auctions the vault refused to start with StalePrice.
    uint256 public auctionsStale;
    uint256 public bids;
    uint256 public restarts;
    /// Restarts the vault refused with StalePrice.
    uint256 public restartsStale;
    uint256 public closes;
    uint256 public jumps;
    uint256 public clears;
    /// Mints and part payments the vault refused with DebtBelowMinimum.
    uint256 public minDebtRefusals;
    /// Mints refused with StalePrice inside the window, with every price under 24 hours old and
    /// a component latched: the breaker is what stopped them.
    uint256 public mintsStoppedByJump;
    /// Auctions refused with StalePrice with every price under 96 hours old and a component latched.
    uint256 public auctionsStoppedByJump;

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
        StockIndexFeed feed_,
        MockRoundFeed first,
        MockRoundFeed second,
        address feeRouter_,
        uint256 id_
    ) {
        vault = vault_;
        synth = synth_;
        kyzn = kyzn_;
        usdg = usdg_;
        oracle = oracle_;
        feed = feed_;
        components[0] = first;
        components[1] = second;
        feeRouter = feeRouter_;
        id = id_;
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
        (uint256 heldK, uint256 heldU,) = vault.positions(id, a);
        k = heldK * (k % 31) / 100;
        u = heldU * (u % 31) / 100;
        if (k == 0 && u == 0) return;
        vm.prank(a);
        try vault.withdraw(id, k, u) {} catch {}
    }

    /// Up to the room the position has at current prices (with the fee), so most mints that the
    /// feed allows succeed; one in eight asks for more than the room, and one in eight for a small
    /// amount, around the minimum debt.
    function mint(uint256 who, uint256 amount) external checked {
        address a = actors[who % ACTORS];
        (uint256 synthPrice,) = feed.latestPrice();
        if (synthPrice == 0) return;
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
        debtValue = Math.mulDiv(vault.debtOf(id, a), synthPrice, 1e18, Math.Rounding.Ceil);
        if (roomValue <= debtValue) return;
        uint256 room = (roomValue - debtValue) * 1e18 / synthPrice * 1_000 / 1_010;
        if (room == 0) return;
        if (amount % 8 == 0) {
            amount = room + bound(amount, 1, 1e18);
        } else if (amount % 8 == 1) {
            amount = bound(amount, 1, Math.min(room, 2 * MIN_DEBT));
        } else if (amount % 8 < 5) {
            // Close to the room, so that a fall in $KYZN or a rise in the index puts it under 150%.
            amount = room * bound(amount / 8, 90, 100) / 100;
        } else {
            amount = bound(amount, 1, room);
        }
        vm.prank(a);
        try vault.mint(id, amount) {
            ++mints;
            _checkActing(a);
            // The feed has synced inside the mint and nothing it reads has changed since, so what
            // it says now is what the vault saw.
            if (!feed.isFresh() || _oldestAge() > 24 hours) mintNotFresh = true;
            if (!_inWindow(block.timestamp)) mintOutsideWindow = true;
            if (_anyLatched()) mintWhileJumped = true;
        } catch (bytes memory err) {
            if (_is(err, SiliconVault.StalePrice.selector)) {
                ++mintsStale;
                if (_anyLatched() && _inWindow(block.timestamp) && _oldestAge() <= 24 hours) ++mintsStoppedByJump;
            }
            if (_is(err, SiliconVault.DebtBelowMinimum.selector)) ++minDebtRefusals;
        }
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
            uint256 left = amount % 16 == 0 ? MIN_DEBT - (amount >> 4) % 2 : bound(amount / 4, 0, 2 * MIN_DEBT);
            amount = debt > left ? debt - left : 1;
            if (amount > balance) amount = balance;
        } else {
            amount = bound(amount, 1, balance);
        }
        vm.prank(a);
        try vault.repay(id, amount) {
            _checkActing(a);
        } catch (bytes memory err) {
            if (_is(err, SiliconVault.DebtBelowMinimum.selector)) ++minDebtRefusals;
        }
    }

    // ---------------------------------------------------------------- prices and time

    /// Time moves forward by a short while, into the next mint window, into a weekday hour outside
    /// it, over a weekend, by up to five days, or by hours (long enough for an auction to end).
    /// Chainlink posts again after three gaps in four, a small move each; the fourth leaves the
    /// prices to age.
    function warp(uint256 kind, uint256 x) external checked {
        uint256 k = kind % 8;
        uint256 target;
        if (k == 0) {
            target = block.timestamp + bound(x, 1, 2 hours);
        } else if (k <= 2) {
            target = _nextInWindow(x);
        } else if (k == 3) {
            target = _nextOutsideWindow(x);
        } else if (k == 4) {
            target = _nextWeekend(x);
        } else if (k == 5) {
            target = block.timestamp + bound(x, 1 days, 5 days);
        } else {
            target = block.timestamp + bound(x, 2 hours, 8 hours);
        }
        vm.warp(target);
        if (x % 4 != 0) {
            for (uint256 i; i < COMPONENTS; ++i) {
                _post(i, _latest(i) * (95 + (x >> (8 + 8 * i)) % 11) / 100);
            }
        }
    }

    /// One component posts a new round: five in eight a small move (up to 10%), one in eight to the
    /// edge of the limit (up 30% or down 30%, which is not a jump), two in eight a jump (down 31%
    /// to 80%, or up 31% to 200%), all within 10 and 3,000 USD.
    function moveComponent(uint256 which, uint256 kind, uint256 amount) external checked {
        uint256 i = which % COMPONENTS;
        uint256 previous = _latest(i);
        uint256 next;
        uint256 k = kind % 8;
        if (k < 5) {
            next = previous * bound(amount, 90, 110) / 100;
        } else if (k == 5) {
            next = amount % 2 == 0 ? previous * 13 / 10 : Math.ceilDiv(previous * 7, 10);
        } else if (amount % 2 == 0) {
            next = previous * bound(amount / 2, 20, 69) / 100;
        } else {
            next = previous * bound(amount / 2, 131, 300) / 100;
        }
        _post(i, next);
    }

    /// The guardian accepts the latest round of one component.
    function clearJump(uint256 which) external checked {
        uint256 i = which % COMPONENTS;
        try feed.clearJump(i, components[i].latestRound()) {
            ++clears;
            latched[i] = false;
        } catch {}
    }

    /// Anyone records the rounds checked so far.
    function syncFeed() external checked {
        feed.sync();
    }

    /// $KYZN moves by -60% to +40%, between $0.01 and $100.
    function moveKyzn(uint256 move) external checked {
        uint256 next = oracle.usdPerKyzn() * bound(move, 40, 140) / 100;
        if (next < 0.01e18) next = 0.01e18;
        if (next > 100e18) next = 100e18;
        oracle.set(next);
    }

    // ---------------------------------------------------------------- auctions

    /// Starts an auction on the first account from `who` that owes something and is under 150% at
    /// the latest prices, or, when there is none, on `who` (which the vault refuses).
    function startAuction(uint256 who, uint256 caller) external checked {
        address account = actors[who % ACTORS];
        for (uint256 k; k < ACTORS; ++k) {
            address candidate = actors[(who % ACTORS + k) % ACTORS];
            (,, uint256 ratioBps,) = vault.health(id, candidate);
            if (vault.debtOf(id, candidate) != 0 && ratioBps < 15_000) {
                account = candidate;
                break;
            }
        }
        uint256 kyznPrice = oracle.usdPerKyzn();
        (uint256 synthPrice,) = feed.latestPrice();
        vm.prank(actors[caller % ACTORS]);
        try vault.startAuction(account, id) returns (uint256 auctionId) {
            auctionIds.push(auctionId);
            ++auctionsStarted;
            _recordLiquidation();
            _checkAuctionPrices(vault.auction(auctionId), kyznPrice, synthPrice);
        } catch (bytes memory err) {
            if (_is(err, SiliconVault.StalePrice.selector)) {
                ++auctionsStale;
                if (_anyLatched() && _oldestAge() <= 96 hours) ++auctionsStoppedByJump;
            }
        }
    }

    /// A bid on a running auction (the first from `index`), by the first account from `who` that
    /// holds synth: a small share of its balance or any amount up to it.
    function bid(uint256 who, uint256 index, uint256 maxSynth) external checked {
        (bool found, uint256 auctionId) = _pickAuction(index, false);
        if (!found) return;
        address a;
        uint256 balance;
        for (uint256 k; k < ACTORS && balance == 0; ++k) {
            a = actors[(who % ACTORS + k) % ACTORS];
            balance = synth.balanceOf(a);
        }
        if (balance == 0) return;
        maxSynth = maxSynth % 2 == 0 ? bound(maxSynth / 2, 1, balance / 4 + 1) : bound(maxSynth / 2, 1, balance);
        vm.prank(a);
        try vault.bid(auctionId, maxSynth) {
            ++bids;
        } catch {}
    }

    /// After the end an auction with debt left restarts once (it stays in place, collateral
    /// untouched), when the price is fresh enough to liquidate on; any other end, or the second,
    /// closes it.
    function closeAuction(uint256 index) external checked {
        (bool found, uint256 auctionId) = _pickAuction(index, true);
        if (!found) return;
        SiliconVault.Auction memory before = vault.auction(auctionId);
        bool restartDue = before.debt != 0 && !before.restarted;
        uint256 kyznPrice = oracle.usdPerKyzn();
        (uint256 synthPrice,) = feed.latestPrice();
        try vault.closeAuction(auctionId) {
            SiliconVault.Auction memory after_ = vault.auction(auctionId);
            if (!restartDue) {
                if (after_.account != address(0)) closeBrokeRestartRule = true; // a second end must close
                ++closes;
                return;
            }
            ++restarts;
            _recordLiquidation();
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
            _checkAuctionPrices(after_, kyznPrice, synthPrice);
        } catch (bytes memory err) {
            if (restartDue && _is(err, SiliconVault.StalePrice.selector)) {
                ++restartsStale;
            } else {
                closeReverted = true;
            }
        }
    }

    /// The first auction from `index` that is still held by the vault and has ended (or has not).
    function _pickAuction(uint256 index, bool ended) internal view returns (bool, uint256) {
        uint256 n = auctionIds.length;
        for (uint256 k; k < n; ++k) {
            uint256 candidate = auctionIds[(index % n + k) % n];
            SiliconVault.Auction memory a = vault.auction(candidate);
            if (a.account == address(0)) continue;
            if ((block.timestamp >= a.startedAt + a.duration) == ended) return (true, candidate);
        }
        return (false, 0);
    }

    // ---------------------------------------------------------------- model

    /// The model's view of a component's latest answer.
    function _latest(uint256 i) internal view returns (uint256) {
        return SafeCast.toUint256(components[i].answers(components[i].latestRound()));
    }

    /// Posts a new round of component `i` at `next` (kept between the bounds) and latches the
    /// component when it moved by more than 30% from the round before.
    function _post(uint256 i, uint256 next) internal {
        uint256 previous = _latest(i);
        next = Math.min(Math.max(next, MIN_ANSWER), MAX_ANSWER);
        components[i].set(SafeCast.toInt256(next));
        uint256 diff = next > previous ? next - previous : previous - next;
        if (diff * 10_000 > previous * 3_000) {
            latched[i] = true;
            ++jumps;
        }
    }

    function _anyLatched() internal view returns (bool) {
        for (uint256 i; i < COMPONENTS; ++i) {
            if (latched[i]) return true;
        }
        return false;
    }

    /// Seconds since the oldest component round was posted.
    function _oldestAge() internal view returns (uint256) {
        uint256 oldest = type(uint256).max;
        for (uint256 i; i < COMPONENTS; ++i) {
            uint256 t = components[i].times(components[i].latestRound());
            if (t < oldest) oldest = t;
        }
        return block.timestamp - oldest;
    }

    /// Monday to Friday, 14:30 to 20:00 UTC (no day is marked closed or early-close here).
    function inWindow(uint256 t) external pure returns (bool) {
        return _inWindow(t);
    }

    function _inWindow(uint256 t) internal pure returns (bool) {
        uint256 weekday = (t / 1 days + 4) % 7; // 0 = Sunday; 1 January 1970 was a Thursday
        uint256 second = t % 1 days;
        return weekday >= 1 && weekday <= 5 && second >= 14 hours + 30 minutes && second < 20 hours;
    }

    /// A liquidation started, or restarted: the feed must be fresh for it, and no component latched.
    function _recordLiquidation() internal {
        if (!feed.isFreshForLiquidation() || _oldestAge() > 96 hours) liquidationPriceStale = true;
        if (_anyLatched()) auctionWhileJumped = true;
    }

    /// A new or restarted auction's prices are the oracle value times (100% + premium) and the
    /// floor share, in synth per 1e18 of each collateral token (USDG is valued at $1.00).
    function _checkAuctionPrices(SiliconVault.Auction memory a, uint256 kyznPrice, uint256 synthPrice) internal {
        uint256 start = (10_000 + START_PREMIUM_BPS) * 1e18;
        uint256 floor = FLOOR_BPS * 1e18;
        uint256 usdgValue = 1e12 * 1e18; // one 1e18 of USDG units is 1e12 USDG at $1.00
        if (a.kyznStartPrice != Math.mulDiv(kyznPrice, start, synthPrice * 10_000)) auctionPricesWrong = true;
        if (a.usdgStartPrice != Math.mulDiv(usdgValue, start, synthPrice * 10_000)) auctionPricesWrong = true;
        if (a.kyznFloorPrice != Math.mulDiv(kyznPrice, floor, synthPrice * 10_000)) auctionPricesWrong = true;
        if (a.usdgFloorPrice != Math.mulDiv(usdgValue, floor, synthPrice * 10_000)) auctionPricesWrong = true;
    }

    /// Each account owes nothing, or at least the minimum debt rounded down, less DUST. The accrued
    /// borrow fee is included, which only raises a debt.
    function _checkMinDebt() internal {
        for (uint256 i; i < ACTORS; ++i) {
            uint256 debt = vault.debtOf(id, actors[i]);
            (,, uint256 shares) = vault.positions(id, actors[i]);
            if (shares != 0 && debt + DUST < MIN_DEBT) minDebtBroken = true;
        }
    }

    /// The account that has just minted or repaid owes nothing, or at least the minimum exactly.
    /// The action dripped, so debtOf is the debt rounded down that the vault judged.
    function _checkActing(address a) internal {
        (,, uint256 shares) = vault.positions(id, a);
        if (shares != 0 && vault.debtOf(id, a) < MIN_DEBT) actingMinDebtBroken = true;
    }

    function _is(bytes memory err, bytes4 selector) internal pure returns (bool) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return err.length >= 4 && bytes4(err) == selector;
    }

    // ---------------------------------------------------------------- time targets

    /// A moment inside a later (or this) day's window, strictly after now.
    function _nextInWindow(uint256 x) internal view returns (uint256 t) {
        uint256 offset = 14 hours + 30 minutes + (x / 7) % (5 hours + 30 minutes);
        for (uint256 day = block.timestamp / 1 days + x % 7;; ++day) {
            uint256 weekday = (day + 4) % 7;
            if (weekday == 0 || weekday == 6) continue;
            t = day * 1 days + offset;
            if (t > block.timestamp) return t;
        }
    }

    /// A weekday moment outside the window (before 14:30 or from 20:00), strictly after now.
    function _nextOutsideWindow(uint256 x) internal view returns (uint256 t) {
        uint256 r = (x / 7) % (1 days - 5 hours - 30 minutes);
        uint256 offset = r < 14 hours + 30 minutes ? r : r + 5 hours + 30 minutes;
        for (uint256 day = block.timestamp / 1 days + x % 7;; ++day) {
            uint256 weekday = (day + 4) % 7;
            if (weekday == 0 || weekday == 6) continue;
            t = day * 1 days + offset;
            if (t > block.timestamp) return t;
        }
    }

    /// A moment on a Saturday or Sunday, strictly after now.
    function _nextWeekend(uint256 x) internal view returns (uint256 t) {
        uint256 offset = (x / 7) % 1 days;
        for (uint256 day = block.timestamp / 1 days + x % 7;; ++day) {
            uint256 weekday = (day + 4) % 7;
            if (weekday != 0 && weekday != 6) continue;
            t = day * 1 days + offset;
            if (t > block.timestamp) return t;
        }
    }
}

/// forge-config: default.invariant.runs = 64
/// forge-config: default.invariant.depth = 256
/// The vault on a real StockIndexFeed (two round feeds, the real calendar): a market's synth supply
/// equals its debt; a mint needs a fresh feed and the calendar's window; an auction starts, or
/// restarts, only on prices fresh for liquidation; no auction's price leaves its floor and start;
/// every position owes nothing or the minimum debt; and a jumped component stops mints and
/// liquidations until the guardian clears it.
contract SiliconIndexInvariantTest is Test {
    /// Monday 5 October 2026, 15:00 UTC: inside the mint window.
    uint256 internal constant START = 1_791_212_400;

    MockToken internal kyzn;
    MockToken internal usdg;
    MockKyznOracle internal oracle;
    MarketCalendar internal cal;
    MockRoundFeed internal nvda;
    MockRoundFeed internal amd;
    StockIndexFeed internal feed;
    SiliconSynth internal synth;
    SiliconVault internal vault;
    IndexHandler internal handler;
    uint256 internal id;
    address internal feeRouter = makeAddr("feeRouter");

    function setUp() public {
        vm.warp(START);
        kyzn = new MockToken("KYZN", 18);
        usdg = new MockToken("USDG", 6);
        oracle = new MockKyznOracle(1e18);
        cal = new MarketCalendar(address(this));
        nvda = new MockRoundFeed(8, 200e8);
        amd = new MockRoundFeed(8, 100e8);
        address[] memory feeds = new address[](2);
        feeds[0] = address(nvda);
        feeds[1] = address(amd);
        feed = new StockIndexFeed("kDESIGN / USD", IMarketCalendar(address(cal)), feeds, address(this));
        vault = new SiliconVault(IERC20(address(kyzn)), IERC20(address(usdg)), IKyznUsdOracle(address(oracle)));
        synth = new SiliconSynth("Kyzen Network kDESIGN", "kDESIGN", address(vault));
        id = vault.addMarket(ISiliconSynth(address(synth)), ISiliconFeed(address(feed)));

        vault.setMintFee(id, MINT_FEE_BPS);
        vault.setBorrowFee(id, BORROW_FEE_BPS);
        vault.setLiquidationPenalty(id, PENALTY_BPS);
        vault.setDebtCeiling(id, DEBT_CEILING);
        vault.setMinDebt(id, MIN_DEBT);
        vault.setAuctionDuration(AUCTION_DURATION);
        vault.setAuctionStartPremium(START_PREMIUM_BPS);
        vault.setAuctionFloor(FLOOR_BPS);
        vault.setFeeRouter(feeRouter);

        handler = new IndexHandler(vault, synth, kyzn, usdg, oracle, feed, nvda, amd, feeRouter, id);
        // The handler is the guardian: it clears a jumped component at the latest round.
        feed.setGuardian(address(handler));
        feed.setMethodology("ipfs://kyzen-network-kdesign-methodology", keccak256("kDESIGN methodology"));
        vault.openMarket(id);
        assertEq(vault.unsetSettings(id), 0, "the market opens with every level set");
        // The first account opens a position inside the window, so that every run starts with
        // something to repay, withdraw from and liquidate.
        handler.mint(0, 100e18 + 5);
        assertEq(handler.mints(), 1, "the opening mint");
        targetContract(address(handler));
    }

    // ---------------------------------------------------------------- invariants

    /// (a) Synth supply equals the market's total debt: positions, auctions and bad debt.
    function invariant_supply_equals_debt() public view {
        SiliconVault.Market memory m = vault.market(id);
        assertEq(synth.totalSupply(), m.totalDebt + m.auctionDebt + m.badDebt, "supply != debt");
    }

    /// (b) Every successful mint happened with the feed fresh (no price over 24 hours old, no
    /// component stopped, not paused) and inside Monday to Friday, 14:30 to 20:00 UTC.
    function invariant_mints_need_a_fresh_feed_and_the_window() public view {
        assertFalse(handler.mintNotFresh(), "a mint succeeded on a feed that was not fresh");
        assertFalse(handler.mintOutsideWindow(), "a mint succeeded outside the window");
    }

    /// (c) Every successful startAuction (and restart) happened with the feed fresh for
    /// liquidation: no price over 96 hours old, no component stopped.
    function invariant_auctions_start_only_on_prices_fresh_for_liquidation() public view {
        assertFalse(handler.liquidationPriceStale(), "an auction started on a stale price");
    }

    /// (d) A running auction's price is never below its floor sum nor above its start sum, its floor
    /// is never above its start, and a new or restarted auction's floor and start are the oracle
    /// value times the floor share and (100% + premium).
    function invariant_running_auctions_stay_between_their_floor_and_start() public view {
        assertFalse(handler.auctionPricesWrong(), "an auction was set with prices other than the oracle's");
        assertFalse(handler.closeBrokeRestartRule(), "a restart or close broke the restart rule");
        assertFalse(handler.closeReverted(), "a close after the end reverted");
        for (uint256 i; i < handler.auctionCount(); ++i) {
            uint256 auctionId = handler.auctionIds(i);
            SiliconVault.Auction memory a = vault.auction(auctionId);
            if (a.account == address(0)) continue;
            assertLe(a.kyznFloorPrice, a.kyznStartPrice);
            assertLe(a.usdgFloorPrice, a.usdgStartPrice);
            uint256 floor = Math.mulDiv(a.kyzn, a.kyznFloorPrice, 1e18, Math.Rounding.Ceil)
                + Math.mulDiv(a.usdg, a.usdgFloorPrice, 1e18, Math.Rounding.Ceil);
            uint256 start = Math.mulDiv(a.kyzn, a.kyznStartPrice, 1e18, Math.Rounding.Ceil)
                + Math.mulDiv(a.usdg, a.usdgStartPrice, 1e18, Math.Rounding.Ceil);
            uint256 price = vault.auctionPrice(auctionId);
            if (price != 0) {
                assertGe(price, floor, "an auction is below its floor");
                assertLe(price, start, "an auction is above its start");
            } else {
                assertGe(block.timestamp, a.startedAt + a.duration, "price is zero only once ended");
            }
        }
    }

    /// (e) Every position owes nothing or at least the minimum debt (rounded down) less DUST, at the
    /// end of every run and after every action the handler took; the account that has just minted
    /// or repaid owes nothing or the minimum exactly. A position in an auction owes nothing: the
    /// auction holds its debt. DUST covers the one corner the vault leaves: a position left at
    /// exactly the minimum by a part payment reads a wei under it after another account's mint or
    /// part repay (the finding test below pins that behaviour; the vault checks the minimum only
    /// when the position's owner acts, and each rounding is in the vault's favour).
    function invariant_every_position_owes_nothing_or_the_minimum() public view {
        assertFalse(handler.actingMinDebtBroken(), "an account under the minimum after its own action");
        assertFalse(handler.minDebtBroken(), "a position owed less than the minimum after an action");
        assertEq(vault.market(id).minDebt, MIN_DEBT);
        for (uint256 i; i < 4; ++i) {
            (,, uint256 shares) = vault.positions(id, handler.actor(i));
            if (shares == 0) continue;
            assertGe(vault.debtOf(id, handler.actor(i)) + DUST, MIN_DEBT, "a position owes less than the minimum");
        }
    }

    /// (f) While a component is jumped, no mint and no auction (start or restart) succeeds, and the
    /// feed itself reads the component as jumped until the guardian clears it.
    function invariant_a_jumped_component_stops_mints_and_auctions() public view {
        assertFalse(handler.mintWhileJumped(), "a mint succeeded while a component was jumped");
        assertFalse(handler.auctionWhileJumped(), "an auction started while a component was jumped");
        MockRoundFeed[2] memory components = [nvda, amd];
        for (uint256 i; i < 2; ++i) {
            if (handler.latched(i)) {
                assertTrue(feed.jumped(i), "a jump released without the guardian");
            } else if (components[i].latestRound() - feed.checkedRound(i) <= feed.MAX_SCAN()) {
                assertFalse(feed.jumped(i), "a component stopped without a jump");
            }
        }
    }

    /// What one run did (the log shows the last run). Reach is asserted by the scripted test
    /// below, not here: a run of 256 random calls can miss a path, and a per-run assert would fail
    /// whole campaigns (measured: a 1,000-run campaign held a run with no mint after the opening
    /// one).
    function afterInvariant() external view {
        console2.log("mints / refused on a stale price", handler.mints(), handler.mintsStale());
        console2.log("mints stopped by a jump", handler.mintsStoppedByJump());
        console2.log("auctions / refused on a stale price", handler.auctionsStarted(), handler.auctionsStale());
        console2.log("auctions stopped by a jump", handler.auctionsStoppedByJump());
        console2.log("bids / closes", handler.bids(), handler.closes());
        console2.log("restarts / refused on a stale price", handler.restarts(), handler.restartsStale());
        console2.log("jumps / clears", handler.jumps(), handler.clears());
        console2.log("refused for the minimum debt / bad debt", handler.minDebtRefusals(), vault.market(id).badDebt);
    }

    // ---------------------------------------------------------------- exercise

    /// The campaign is random; this walks each path once, by hand, so that a handler that stopped
    /// reaching one would fail here instead of passing the campaign without touching it. Prices
    /// are $1.00 for $KYZN and 100 USD for the index at the start.
    function test_the_handler_reaches_every_path() public {
        uint256 mintAmount = 100e18 + 5; // 8 divides 100e18, so this is an ordinary-size mint

        // The opening mint (setUp) was inside the window on a fresh, clean feed.
        assertTrue(feed.isFresh());
        assertEq(handler.mints(), 1, "a mint in the window");
        _assertInvariants();

        // Outside the window (a weekday night), and over a weekend: the mint is refused, though
        // Chainlink has just posted.
        handler.warp(3, 1);
        assertFalse(cal.isMintWindow(block.timestamp));
        assertTrue(feed.isFreshForLiquidation());
        handler.mint(1, mintAmount);
        handler.warp(4, 1);
        assertFalse(cal.isMintWindow(block.timestamp));
        handler.mint(1, mintAmount);
        assertEq(handler.mintsStale(), 2, "refused outside the window");
        assertEq(handler.mints(), 1);

        // Back inside the window it works again.
        handler.warp(1, 1);
        assertTrue(cal.isMintWindow(block.timestamp));
        handler.mint(1, mintAmount);
        assertEq(handler.mints(), 2, "a mint in the next window");
        _assertInvariants();

        // A component jumps by 31%: the breaker stops the mint inside the window with fresh prices.
        handler.moveComponent(0, 7, 1);
        assertEq(handler.jumps(), 1);
        assertTrue(feed.jumped(0));
        assertFalse(feed.isFresh());
        handler.mint(2, mintAmount);
        assertEq(handler.mintsStoppedByJump(), 1, "the breaker stopped a mint");
        assertEq(handler.mints(), 2);
        _assertInvariants();

        // $KYZN falls to $0.064: the two positions with debt are under 150%. The breaker stops the
        // liquidation too, until the guardian clears the component; then both start.
        handler.moveKyzn(0);
        handler.moveKyzn(0);
        handler.moveKyzn(0);
        handler.startAuction(0, 1);
        assertEq(handler.auctionsStoppedByJump(), 1, "the breaker stopped an auction");
        assertEq(handler.auctionsStarted(), 0);
        handler.clearJump(0);
        assertEq(handler.clears(), 1);
        assertFalse(feed.jumped(0));
        handler.startAuction(0, 1);
        handler.startAuction(1, 0);
        assertEq(handler.auctionsStarted(), 2, "two auctions after the clear");
        // The third account takes a small loan on what $KYZN is worth now, then $KYZN falls again.
        handler.mint(2, 20e18 + 5);
        assertEq(handler.mints(), 3, "a mint after the clear");
        handler.moveKyzn(0);
        _assertInvariants();

        // A bid takes part of the first auction.
        handler.bid(0, 0, 18e18);
        assertEq(handler.bids(), 1);

        // Five days without a post: nothing is fresh for liquidation, and an ended auction cannot
        // restart; after a post it restarts, and both end again and close with bad debt.
        handler.warp(5, 5 days);
        assertFalse(feed.isFreshForLiquidation());
        handler.closeAuction(0);
        assertEq(handler.restartsStale(), 1, "a restart waited for a price");
        assertEq(handler.restarts(), 0);
        handler.startAuction(2, 1);
        assertEq(handler.auctionsStale(), 2, "no auction on a stale price");
        handler.warp(0, 1);
        assertTrue(feed.isFreshForLiquidation());
        handler.closeAuction(0);
        handler.closeAuction(0);
        assertEq(handler.restarts(), 2, "both auctions restarted");
        _assertInvariants();
        handler.warp(0, 2 hours);
        handler.closeAuction(0);
        handler.closeAuction(0);
        assertEq(handler.closes(), 2, "both auctions closed");
        assertGt(vault.market(id).badDebt, 0, "the shortfall is bad debt");
        _assertInvariants();

        // A mint below the minimum debt is refused whatever the prices.
        handler.mint(3, 1);
        assertEq(handler.minDebtRefusals(), 1, "the minimum debt");
        _assertInvariants();
    }

    /// Pins the one-wei behaviour that invariant (e)'s DUST allows for. A part payment can leave a
    /// position at exactly the minimum debt (the vault accepts it: debt rounded down is the
    /// minimum). The next mint by anyone else rounds its own debt shares up, which lowers the debt
    /// per share by less than a wei, so the first position then reads one wei under the minimum:
    /// at most a wei per later mint, far below DUST. The vault checks the minimum when a
    /// position's owner mints or repays, which still holds. The fuzzer reaches this corner (the
    /// handler's part repays often leave exactly the minimum), which is why (e) has DUST.
    /// This test passes before and after any fix.
    function test_finding_a_position_left_at_the_minimum_reads_a_wei_under_after_another_mint() public {
        address first = handler.actor(0);
        handler.warp(1, 131); // a week on, in the window, so that the borrow fee has accrued
        // The handler's repay of 4 times the minimum (a multiple of 32) leaves exactly the minimum.
        handler.repay(0, 4 * vault.market(id).minDebt);
        uint256 atMinimum = vault.debtOf(id, first);
        assertEq(atMinimum, MIN_DEBT, "the part payment leaves exactly the minimum");
        handler.mint(3, 21_202); // the fourth account takes a loan
        assertEq(handler.mints(), 2);
        uint256 after_ = vault.debtOf(id, first);
        console2.log("debt at the minimum / after another account's mint", atMinimum, after_);
        assertLe(after_, atMinimum, "another mint never raises a debt");
        assertGe(after_ + 1, atMinimum, "and lowers it by a wei at most");
        assertGe(after_ + DUST, MIN_DEBT, "which (e) allows for");
    }

    /// The handler's own reading of the window (used by the invariants) is the calendar's, over
    /// five years from the start, and at the edges of a day.
    function testFuzz_the_handlers_window_is_the_calendars(uint256 t) public view {
        t = bound(t, START, START + 5 * 365 days);
        assertEq(handler.inWindow(t), cal.isMintWindow(t));
    }

    function test_the_window_edges() public view {
        uint256 monday = 1_791_158_400; // 2026-10-05 00:00 UTC
        assertFalse(handler.inWindow(monday + 14 hours + 30 minutes - 1));
        assertTrue(handler.inWindow(monday + 14 hours + 30 minutes));
        assertTrue(handler.inWindow(monday + 20 hours - 1));
        assertFalse(handler.inWindow(monday + 20 hours));
        assertFalse(handler.inWindow(monday - 1 days + 15 hours)); // Sunday
        assertFalse(handler.inWindow(monday + 5 days + 15 hours)); // Saturday
        assertTrue(handler.inWindow(monday + 4 days + 15 hours)); // Friday
        for (uint256 d; d < 7; ++d) {
            for (uint256 h; h < 24; ++h) {
                uint256 t = monday + d * 1 days + h * 1 hours + 30 minutes;
                assertEq(handler.inWindow(t), cal.isMintWindow(t));
            }
        }
    }

    function _assertInvariants() internal view {
        invariant_supply_equals_debt();
        invariant_mints_need_a_fresh_feed_and_the_window();
        invariant_auctions_start_only_on_prices_fresh_for_liquidation();
        invariant_running_auctions_stay_between_their_floor_and_start();
        invariant_every_position_owes_nothing_or_the_minimum();
        invariant_a_jumped_component_stops_mints_and_auctions();
    }
}
