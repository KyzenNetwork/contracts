// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {Reserve} from "../../src/Reserve.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {Fixture} from "../utils/Fixture.sol";
import {MockStockToken} from "../mocks/MockStockToken.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {MockFeed} from "../mocks/MockFeed.sol";
import {MockVenue} from "../mocks/MockVenue.sol";

/// Random redemptions, claims, issuer pauses and burns, deposits, keeper buys and sales, and time.
contract ReserveHandler is Test {
    KyznToken internal token;
    Reserve internal reserve;
    MockStockToken internal nvda;
    MockStockToken internal amd;
    MockVenue internal venue;
    address internal keeper;
    MockFeed internal ethUsd;
    MockFeed internal nvdaFeed;
    MockFeed internal amdFeed;
    address[3] internal actors;

    bool public backingFell;
    uint256 public lastSupply;
    bool public supplyRose;
    uint256 public buys;
    uint256 public sells;
    /// AMD the issuer burned from the Reserve (adminBurn, SPEC 3.2a).
    uint256 public amdBurned;
    uint256 public claimsCollected;
    /// A claim paid other than its claim x min(balance, totalClaims) / totalClaims, or left a record.
    bool public claimMispaid;
    /// A claim left the other claims a smaller share of the balance per unit claimed.
    bool public claimShareFell;
    /// A redemption or sale took AMD reserved for claims: min(balance, totalClaims) fell.
    bool public tookFromClaims;

    constructor(
        KyznToken token_,
        Reserve reserve_,
        MockStockToken nvda_,
        MockStockToken amd_,
        MockVenue venue_,
        address keeper_,
        MockFeed[3] memory feeds_
    ) {
        token = token_;
        reserve = reserve_;
        nvda = nvda_;
        amd = amd_;
        venue = venue_;
        keeper = keeper_;
        ethUsd = feeds_[0];
        nvdaFeed = feeds_[1];
        amdFeed = feeds_[2];
        actors = [makeAddr("holder1"), makeAddr("holder2"), makeAddr("holder3")];
        lastSupply = token_.totalSupply();
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    function redeem(uint256 who, uint256 amount) external {
        address a = actors[who % 3];
        uint256 balance = token.balanceOf(a);
        if (balance == 0) return;
        amount = bound(amount, 1, balance);
        uint256 s0 = token.totalSupply();
        uint256 e0 = address(reserve).balance;
        uint256 n0 = _available(nvda);
        uint256 m0 = _available(amd);
        uint256 reserved = _reservedForClaims();
        vm.startPrank(a);
        token.approve(address(reserve), amount);
        reserve.redeem(amount);
        vm.stopPrank();
        if (_reservedForClaims() < reserved) tookFromClaims = true;
        uint256 s1 = token.totalSupply();
        if (
            address(reserve).balance * s0 < e0 * s1 || _available(nvda) * s0 < n0 * s1 || _available(amd) * s0 < m0 * s1
        ) backingFell = true;
        if (s1 > lastSupply) supplyRose = true;
        lastSupply = s1;
    }

    /// Collects an AMD claim: in full while the Reserve's AMD covers totalClaims, otherwise the
    /// claim x balance / totalClaims (an issuer burn left the claims short). A claim that pays
    /// something waits for the unpause; one that pays nothing clears at once.
    function claim(uint256 who) external {
        address a = actors[who % 3];
        uint256 owed = reserve.claims(address(amd), a);
        if (owed == 0) return;
        uint256 total = reserve.totalClaims(address(amd));
        uint256 held = amd.balanceOf(address(reserve));
        uint256 expected = held < total ? Math.mulDiv(owed, held, total) : owed;
        if (amd.paused() && expected != 0) return;
        uint256 before = amd.balanceOf(a);
        vm.prank(a);
        reserve.claim(address(amd));
        ++claimsCollected;
        if (amd.balanceOf(a) - before != expected || reserve.claims(address(amd), a) != 0) claimMispaid = true;
        uint256 total1 = reserve.totalClaims(address(amd));
        uint256 held1 = amd.balanceOf(address(reserve));
        if (held < total && held1 * total < held * total1) claimShareFell = true;
    }

    /// The issuer burns AMD from the Reserve, claims included: it leaves 0% to 150% of what the
    /// claims need (0% to 100% of the balance when nothing is claimed), so burns land in the
    /// shortfall, around it and at zero.
    function issuerBurn(uint256 keepBps) external {
        uint256 held = amd.balanceOf(address(reserve));
        uint256 owed = reserve.totalClaims(address(amd));
        uint256 keep = owed == 0
            ? Math.mulDiv(held, bound(keepBps, 0, 10_000), 10_000)
            : Math.mulDiv(owed, bound(keepBps, 0, 15_000), 10_000);
        if (keep >= held) return;
        amd.adminBurn(address(reserve), held - keep);
        amdBurned += held - keep;
    }

    function setPaused(bool paused) external {
        amd.setPaused(paused);
    }

    function deposit(uint256 eth, uint256 nvdaAmount) external {
        vm.deal(address(reserve), address(reserve).balance + bound(eth, 0, 10 ether));
        nvda.mint(address(reserve), bound(nvdaAmount, 0, 100e18));
    }

    /// The AMD reserved for claims: all of totalClaims while the balance covers it, else the balance.
    function _reservedForClaims() internal view returns (uint256) {
        return Math.min(amd.balanceOf(address(reserve)), reserve.totalClaims(address(amd)));
    }

    function _available(MockStockToken t) internal view returns (uint256) {
        uint256 balance = t.balanceOf(address(reserve));
        uint256 owed = reserve.totalClaims(address(t));
        return balance > owed ? balance - owed : 0;
    }

    /// The keeper buys NVDA or AMD with up to 1 ETH through the venue.
    function keeperBuy(uint256 which, uint256 ethIn) external {
        ethIn = bound(ethIn, 0.01 ether, 1 ether);
        if (address(reserve).balance < ethIn) return;
        (MockStockToken asset, MockFeed feed) = _pick(which);
        bytes memory data = abi.encodeCall(MockVenue.buyAsset, (asset, feed, ethUsd, ethIn));
        vm.prank(keeper);
        try reserve.buy(address(asset), address(venue), data, ethIn, 0) {
            ++buys;
        } catch {}
    }

    /// The keeper sells up to 10 NVDA or AMD, paid in WETH. Bounded by the raw balance, not the
    /// unclaimed balance: a proposed sale can exceed what claims leave available, so it is the
    /// contract's own claims check in sell() (never selling more than the unclaimed balance)
    /// that this invariant exercises, rather than this handler quietly avoiding the case.
    function keeperSell(uint256 which, uint256 amount) external {
        (MockStockToken asset, MockFeed feed) = _pick(which);
        uint256 balance = asset.balanceOf(address(reserve));
        if (balance == 0) return;
        amount = bound(amount, 1, balance < 10e18 ? balance : 10e18);
        bytes memory data = abi.encodeCall(MockVenue.sellAsset, (asset, feed, ethUsd, amount, true));
        uint256 reserved = _reservedForClaims();
        vm.prank(keeper);
        try reserve.sell(address(asset), address(venue), data, amount, 0) {
            ++sells;
        } catch {}
        if (_reservedForClaims() < reserved) tookFromClaims = true;
    }

    /// Time passes inside the purchase window, so keeper trades can land: up to 2 hours at a
    /// time, rolling to the next weekday's 13:30 UTC open once past the 21:00 close. The feeds
    /// update.
    function pass(uint256 minutes_) external {
        uint256 t = block.timestamp + bound(minutes_, 1, 120) * 1 minutes;
        if (!PriceLib.inPurchaseWindow(t)) t = _nextOpen(t);
        vm.warp(t);
        ethUsd.set(2_500e8, block.timestamp);
        nvdaFeed.set(200e8, block.timestamp);
        amdFeed.set(150e8, block.timestamp);
    }

    /// The first weekday 13:30 UTC after `t`.
    function _nextOpen(uint256 t) internal pure returns (uint256 open) {
        open = t / 1 days * 1 days + 13 hours + 30 minutes;
        if (open <= t) open += 1 days;
        while (!PriceLib.inPurchaseWindow(open)) {
            open += 1 days;
        }
    }

    function _pick(uint256 which) internal view returns (MockStockToken asset, MockFeed feed) {
        if (which % 2 == 0) return (nvda, nvdaFeed);
        return (amd, amdFeed);
    }
}

/// SPEC Step 4 Reserve invariants: redemption solvency (claims never exceed holdings but by an
/// issuer burn, and then share it pro-rata), backing per token never falls on a redemption,
/// supply never increases.
contract ReserveInvariantTest is Fixture {
    ReserveHandler internal handler;

    function setUp() public override {
        super.setUp();
        MockVenue venue = new MockVenue(IWETH(address(weth)));
        vm.deal(address(venue), 1_000 ether);
        reserve.queueTarget(address(venue), true);
        uint16[5] memory w = [uint16(4_000), 2_000, 2_000, 1_000, 1_000];
        registry.publish(w, keccak256("memo 1"), "https://kyzen.network/scheduler/memo-1", uint64(block.timestamp));
        handler = new ReserveHandler(token, reserve, nvda, amd, venue, keeper, [ethUsd, nvdaFeed, amdFeed]);
        for (uint256 i; i < 3; ++i) {
            token.transfer(handler.actor(i), 10_000_000e18);
        }
        _launch();
        vm.deal(address(reserve), 100 ether);
        nvda.mint(address(reserve), 1_000e18);
        amd.mint(address(reserve), 500e18);
        vm.warp(MONDAY_1400 + 2 days); // Wednesday 14:00 UTC: the venue is live and the first rotation has executed
        _refreshFeeds();
        targetContract(address(handler));
    }

    /// Claims never exceed holdings, except by what the issuer burned from the Reserve: only a burn
    /// can leave the claims short (27 September 2026).
    function invariant_claims_never_exceed_holdings() public view {
        assertGe(amd.balanceOf(address(reserve)) + handler.amdBurned(), reserve.totalClaims(address(amd)));
        assertGe(nvda.balanceOf(address(reserve)), reserve.totalClaims(address(nvda)));
    }

    /// A shortfall is shared: every claim pays the same fraction of itself, no claim leaves the
    /// others a smaller share, and no redemption or sale takes what is reserved for claims.
    function invariant_claims_share_a_shortfall_pro_rata() public view {
        assertFalse(handler.claimMispaid());
        assertFalse(handler.claimShareFell());
        assertFalse(handler.tookFromClaims());
    }

    function invariant_claims_add_up() public view {
        uint256 sum;
        for (uint256 i; i < 3; ++i) {
            sum += reserve.claims(address(amd), handler.actor(i));
        }
        assertEq(sum, reserve.totalClaims(address(amd)));
    }

    /// The handler's claim path after a burn runs, and pays: two claims recorded while AMD is
    /// paused, the Reserve's AMD burned to about a third of them, both collected pro-rata.
    function test_handler_collects_claims_pro_rata_after_a_burn() public {
        handler.setPaused(true);
        handler.redeem(0, 1_000_000e18);
        handler.redeem(1, 2_000_000e18);
        uint256 owed = reserve.totalClaims(address(amd));
        assertGt(owed, 0);
        handler.issuerBurn(3_333); // keeps a third of what the claims need
        handler.setPaused(false);
        handler.claim(0);
        handler.claim(1);
        assertEq(handler.claimsCollected(), 2);
        assertEq(reserve.totalClaims(address(amd)), 0);
        assertEq(amd.balanceOf(address(reserve)), 0, "the claims took the whole remaining balance");
        invariant_claims_share_a_shortfall_pro_rata();
        invariant_claims_never_exceed_holdings();
    }

    function invariant_backing_per_token_never_falls_on_redemption() public view {
        assertFalse(handler.backingFell());
    }

    function invariant_supply_never_increases() public view {
        assertFalse(handler.supplyRose());
        assertLe(token.totalSupply(), token.INITIAL_SUPPLY());
    }
}
