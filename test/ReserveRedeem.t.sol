// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Reserve} from "../src/Reserve.sol";
import {Fixture} from "./utils/Fixture.sol";
import {MockFeed} from "./mocks/MockFeed.sol";
import {MockStockToken} from "./mocks/MockStockToken.sol";
import {HostileToken} from "./mocks/HostileToken.sol";
import {MockVenue} from "./mocks/MockVenue.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";

contract BlockableToken is ERC20 {
    bool public blocked;

    constructor() ERC20("Block", "BLK") {}

    function mint(address to, uint256 a) external {
        _mint(to, a);
    }

    function setBlocked(bool b) external {
        blocked = b;
    }

    function _update(address f, address t, uint256 v) internal override {
        require(!blocked, "blocked");
        super._update(f, t, v);
    }
}

/// Redemption at backing minus 2%, in kind, against total supply (SPEC 3.2).
contract ReserveRedeemTest is Fixture {
    /// Gas for a call that meets hostile assets: about three times what the Reserve needs with
    /// BALANCE_GAS and TRANSFER_GAS, and too little to finish a redemption if a hostile call
    /// could take all but 1/64 of the gas left.
    uint256 internal constant HOSTILE_GAS = 1_000_000;

    function setUp() public override {
        super.setUp();
        token.transfer(alice, 10_000_000e18); // 1% of supply each
        token.transfer(bob, 10_000_000e18);
        _launch();
        vm.deal(address(reserve), 100 ether);
        nvda.mint(address(reserve), 1_000e18);
        amd.mint(address(reserve), 500e18);
    }

    function _redeem(address who, uint256 amount) internal {
        vm.startPrank(who);
        token.approve(address(reserve), amount);
        reserve.redeem(amount);
        vm.stopPrank();
    }

    /// Lists a HostileToken holding 100 in the Reserve (after its 24-hour wait).
    function _listHostile() internal returns (HostileToken hostile) {
        hostile = new HostileToken();
        hostile.mint(address(reserve), 100e18);
        reserve.addAsset(address(hostile), address(new MockFeed(8, 100e8)), 2);
        vm.warp(block.timestamp + 24 hours);
        reserve.listAsset(address(hostile));
    }

    /// Final review item 1: a listed asset whose balance cannot be read, because balanceOf
    /// reverts, burns all the gas it gets or answers short, is skipped; every other asset and
    /// the ETH still pay, and nothing is owed in the skipped assets.
    function test_unreadable_asset_is_skipped_and_the_rest_pays() public {
        HostileToken reverting = _listHostile();
        HostileToken burning = _listHostile();
        HostileToken short_ = _listHostile();
        reverting.setBalanceMode(HostileToken.Mode.Revert);
        burning.setBalanceMode(HostileToken.Mode.BurnGas);
        short_.setBalanceMode(HostileToken.Mode.ShortAnswer);

        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        token.approve(address(reserve), 10_000_000e18);
        vm.expectEmit(address(reserve));
        emit Reserve.AssetUnreadable(address(reverting));
        vm.expectEmit(address(reserve));
        emit Reserve.AssetUnreadable(address(burning));
        vm.expectEmit(address(reserve));
        emit Reserve.AssetUnreadable(address(short_));
        vm.expectEmit(address(reserve));
        emit Reserve.Redeemed(alice, 10_000_000e18, 0.98 ether);
        reserve.redeem{gas: HOSTILE_GAS}(10_000_000e18);
        vm.stopPrank();

        assertEq(alice.balance - ethBefore, 0.98 ether);
        assertEq(nvda.balanceOf(alice), 9.8e18);
        assertEq(amd.balanceOf(alice), 4.9e18);
        assertEq(token.totalSupply(), 990_000_000e18);
        HostileToken[3] memory skipped = [reverting, burning, short_];
        for (uint256 i; i < skipped.length; ++i) {
            assertEq(reserve.claims(address(skipped[i]), alice), 0);
            assertEq(reserve.totalClaims(address(skipped[i])), 0);
            skipped[i].setBalanceMode(HostileToken.Mode.Normal);
            assertEq(skipped[i].balanceOf(alice), 0);
            assertEq(skipped[i].balanceOf(address(reserve)), 100e18);
        }
    }

    function test_preview_reports_zero_for_an_unreadable_asset() public {
        HostileToken reverting = _listHostile();
        HostileToken burning = _listHostile();
        reverting.setBalanceMode(HostileToken.Mode.Revert);
        burning.setBalanceMode(HostileToken.Mode.BurnGas);
        (uint256 ethOut, address[] memory tokens, uint256[] memory amounts) =
            reserve.previewRedeem{gas: HOSTILE_GAS}(10_000_000e18);
        assertEq(ethOut, 0.98 ether);
        assertEq(tokens.length, 5);
        assertEq(tokens[3], address(reverting));
        assertEq(tokens[4], address(burning));
        assertEq(amounts[0], 9.8e18); // NVDA
        assertEq(amounts[1], 4.9e18); // AMD
        assertEq(amounts[2], 0); // MU: none held
        assertEq(amounts[3], 0); // unreadable: redeem skips it
        assertEq(amounts[4], 0);
    }

    function test_a_transfer_that_burns_gas_becomes_a_claim() public {
        HostileToken burning = _listHostile();
        burning.setTransferMode(HostileToken.Mode.BurnGas);
        vm.startPrank(alice);
        token.approve(address(reserve), 10_000_000e18);
        vm.expectEmit(address(reserve));
        emit Reserve.ClaimRecorded(alice, address(burning), 0.98e18);
        reserve.redeem{gas: HOSTILE_GAS}(10_000_000e18);
        vm.stopPrank();
        assertEq(nvda.balanceOf(alice), 9.8e18);
        assertEq(amd.balanceOf(alice), 4.9e18);
        assertEq(reserve.claims(address(burning), alice), 0.98e18);
        assertEq(reserve.totalClaims(address(burning)), 0.98e18);

        burning.setTransferMode(HostileToken.Mode.Normal);
        vm.prank(alice);
        reserve.claim(address(burning));
        assertEq(burning.balanceOf(alice), 0.98e18);
    }

    /// A transfer pays when it answers true or nothing; any other answer records a claim.
    function test_transfer_answers_decide_paid_or_claimed() public {
        HostileToken silent = _listHostile();
        HostileToken refusing = _listHostile();
        HostileToken short_ = _listHostile();
        HostileToken reverting = _listHostile();
        silent.setTransferMode(HostileToken.Mode.AnswerNothing);
        refusing.setTransferMode(HostileToken.Mode.AnswerFalse);
        short_.setTransferMode(HostileToken.Mode.ShortAnswer);
        reverting.setTransferMode(HostileToken.Mode.Revert);
        _redeem(alice, 10_000_000e18);

        assertEq(silent.balanceOf(alice), 0.98e18);
        assertEq(reserve.claims(address(silent), alice), 0);
        HostileToken[3] memory claimed = [refusing, short_, reverting];
        for (uint256 i; i < claimed.length; ++i) {
            assertEq(claimed[i].balanceOf(alice), 0);
            assertEq(reserve.claims(address(claimed[i]), alice), 0.98e18);
        }
    }

    function test_pays_one_percent_times_98_percent_of_everything() public {
        uint256 ethBefore = alice.balance;
        vm.startPrank(alice);
        token.approve(address(reserve), 10_000_000e18);
        vm.expectEmit(address(reserve));
        emit Reserve.Redeemed(alice, 10_000_000e18, 0.98 ether);
        reserve.redeem(10_000_000e18);
        vm.stopPrank();
        assertEq(alice.balance - ethBefore, 0.98 ether);
        assertEq(nvda.balanceOf(alice), 9.8e18);
        assertEq(amd.balanceOf(alice), 4.9e18);
        assertEq(token.balanceOf(alice), 0);
        assertEq(token.totalSupply(), 990_000_000e18);
    }

    function test_redemption_is_untaxed() public {
        _redeem(alice, 10_000_000e18);
        assertEq(token.balanceOf(address(token)), 0);
        assertEq(token.balanceOf(address(reserve)), 0);
    }

    function test_the_2_percent_stays_and_backing_rises() public {
        (uint256 before,) = reserve.backingPerToken();
        _redeem(alice, 10_000_000e18);
        (uint256 afterRedeem,) = reserve.backingPerToken();
        assertGt(afterRedeem, before);
        assertEq(address(reserve).balance, 100 ether - 0.98 ether);
    }

    function test_redeems_back_to_back_with_no_cooldown() public {
        _redeem(alice, 5_000_000e18);
        _redeem(alice, 5_000_000e18);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_paused_token_becomes_a_claim() public {
        amd.setPaused(true);
        _redeem(alice, 10_000_000e18);
        assertEq(nvda.balanceOf(alice), 9.8e18);
        assertEq(amd.balanceOf(alice), 0);
        assertEq(reserve.claims(address(amd), alice), 4.9e18);
        assertEq(reserve.totalClaims(address(amd)), 4.9e18);

        vm.prank(alice);
        vm.expectRevert();
        reserve.claim(address(amd)); // still paused

        amd.setPaused(false);
        vm.expectEmit(address(reserve));
        emit Reserve.Claimed(alice, address(amd), 4.9e18);
        vm.prank(alice);
        reserve.claim(address(amd));
        assertEq(amd.balanceOf(alice), 4.9e18);
        assertEq(reserve.totalClaims(address(amd)), 0);
        assertEq(reserve.claims(address(amd), alice), 0);
    }

    function test_nothing_to_claim_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Reserve.NothingToClaim.selector);
        reserve.claim(address(amd));
    }

    function test_claims_are_excluded_from_later_redemptions_and_backing() public {
        amd.setPaused(true);
        _redeem(alice, 10_000_000e18); // 4.9 AMD owed to alice
        _redeem(bob, 10_000_000e18); // bob's share comes from the 495.1 AMD not owed
        uint256 expected = Math.mulDiv(500e18 - 4.9e18, 10_000_000e18 * 9_800, 990_000_000e18 * 10_000);
        assertEq(reserve.claims(address(amd), bob), expected);
        assertEq(reserve.totalClaims(address(amd)), 4.9e18 + expected);
        assertEq(amd.balanceOf(address(reserve)), 500e18);

        (uint256 value,) = reserve.reserveValue();
        uint256 eth = address(reserve).balance * 2_500;
        uint256 nvdaValue = nvda.balanceOf(address(reserve)) * 200;
        uint256 amdValue = (500e18 - 4.9e18 - expected) * 150;
        assertEq(value, eth + nvdaValue + amdValue);
    }

    // ------------------------------------------------ claims after an issuer burn (27 September 2026)

    /// Records AMD claims for alice and bob (AMD paused at both redemptions) and returns them.
    function _amdClaims() internal returns (uint256 aliceOwed, uint256 bobOwed) {
        amd.setPaused(true);
        _redeem(alice, 10_000_000e18);
        _redeem(bob, 10_000_000e18);
        aliceOwed = reserve.claims(address(amd), alice);
        bobOwed = reserve.claims(address(amd), bob);
        assertEq(reserve.totalClaims(address(amd)), aliceOwed + bobOwed);
    }

    /// The issuer burns AMD from the Reserve (adminBurn, SPEC 3.2a) until `left` remains.
    function _burnAmdTo(uint256 left) internal {
        amd.adminBurn(address(reserve), amd.balanceOf(address(reserve)) - left);
        assertEq(amd.balanceOf(address(reserve)), left);
    }

    /// A burn that leaves the Reserve short of what the claims need: every claim pays the same
    /// fraction, amount x balance / totalClaims, rounded down, and clears the whole record.
    /// Claimed carries what was paid.
    function test_claims_after_an_issuer_burn_share_the_shortfall() public {
        (uint256 aliceOwed, uint256 bobOwed) = _amdClaims();
        uint256 owed = aliceOwed + bobOwed;
        uint256 left = owed * 4 / 10;
        _burnAmdTo(left);
        amd.setPaused(false);

        uint256 alicePaid = Math.mulDiv(aliceOwed, left, owed);
        assertLt(alicePaid, aliceOwed);
        vm.expectEmit(address(reserve));
        emit Reserve.Claimed(alice, address(amd), alicePaid);
        vm.prank(alice);
        reserve.claim(address(amd));
        assertEq(amd.balanceOf(alice), alicePaid);
        assertEq(reserve.claims(address(amd), alice), 0, "the whole record clears");
        assertEq(reserve.totalClaims(address(amd)), bobOwed, "totalClaims falls by the whole record");

        uint256 bobPaid = left - alicePaid; // the last claim takes the rest
        assertApproxEqAbs(bobPaid, Math.mulDiv(bobOwed, left, owed), 1, "bob bears the same haircut");
        vm.expectEmit(address(reserve));
        emit Reserve.Claimed(bob, address(amd), bobPaid);
        vm.prank(bob);
        reserve.claim(address(amd));
        assertEq(amd.balanceOf(bob), bobPaid);
        assertEq(reserve.totalClaims(address(amd)), 0);
        assertEq(amd.balanceOf(address(reserve)), 0);

        vm.prank(alice);
        vm.expectRevert(Reserve.NothingToClaim.selector);
        reserve.claim(address(amd));
    }

    /// A burn that leaves at least what the claims need falls on the other holders only: every
    /// claim still pays in full, down to a balance exactly equal to totalClaims.
    function test_claims_pay_in_full_while_the_balance_covers_them() public {
        (uint256 aliceOwed, uint256 bobOwed) = _amdClaims();
        _burnAmdTo(aliceOwed + bobOwed);
        amd.setPaused(false);
        (,, uint256[] memory amounts) = reserve.previewRedeem(1_000_000e18);
        assertEq(amounts[1], 0, "nothing of AMD is left for redemptions");

        vm.expectEmit(address(reserve));
        emit Reserve.Claimed(bob, address(amd), bobOwed);
        vm.prank(bob);
        reserve.claim(address(amd));
        vm.prank(alice);
        reserve.claim(address(amd));
        assertEq(amd.balanceOf(alice), aliceOwed);
        assertEq(amd.balanceOf(bob), bobOwed);
        assertEq(amd.balanceOf(address(reserve)), 0);
        assertEq(reserve.totalClaims(address(amd)), 0);
    }

    /// A burn of the whole balance: claims still clear, pay nothing and say so, so no record is
    /// stuck. AMD that arrives afterwards is an ordinary holding again.
    function test_after_a_burn_to_zero_claims_clear_and_pay_nothing() public {
        (uint256 aliceOwed,) = _amdClaims();
        _burnAmdTo(0);
        amd.setPaused(false);

        vm.expectEmit(address(reserve));
        emit Reserve.Claimed(alice, address(amd), 0);
        vm.prank(alice);
        reserve.claim(address(amd));
        assertEq(amd.balanceOf(alice), 0);
        assertEq(reserve.claims(address(amd), alice), 0);
        vm.prank(bob);
        reserve.claim(address(amd));
        assertEq(reserve.totalClaims(address(amd)), 0);
        assertGt(aliceOwed, 0);

        amd.mint(address(reserve), 100e18);
        (,, uint256[] memory amounts) = reserve.previewRedeem(1_000_000e18);
        assertEq(amounts[1], Math.mulDiv(100e18, 1_000_000e18 * 9_800, token.totalSupply() * 10_000));
    }

    /// A claim that pays nothing makes no transfer, so it clears even while the issuer keeps the
    /// token paused. A claim that pays something waits for the unpause, record intact.
    function test_a_zero_payout_clears_even_while_the_token_is_paused() public {
        (uint256 aliceOwed, uint256 bobOwed) = _amdClaims();
        _burnAmdTo(0); // still paused
        vm.prank(alice);
        reserve.claim(address(amd));
        assertEq(reserve.claims(address(amd), alice), 0);
        assertEq(reserve.totalClaims(address(amd)), bobOwed);

        amd.setPaused(false); // the paused mock refuses mints too
        amd.mint(address(reserve), bobOwed / 2);
        amd.setPaused(true);
        vm.prank(bob);
        vm.expectRevert(); // pays bobOwed / 2: the paused token refuses the transfer
        reserve.claim(address(amd));
        assertEq(reserve.claims(address(amd), bob), bobOwed, "the record stays");
        assertGt(aliceOwed, 0);
    }

    /// Claims come first, as in every redemption: while the balance is below totalClaims a
    /// redemption pays none of that asset and the keeper cannot sell it. AMD the keeper buys after
    /// a burn refills the claims before redemptions see any of it. So a claim collected after the
    /// buy (bob, in full) can pay a larger fraction than one collected before it (alice).
    function test_tokens_bought_after_a_burn_refill_the_claims_before_redemptions() public {
        (uint256 aliceOwed, uint256 bobOwed) = _amdClaims();
        uint256 owed = aliceOwed + bobOwed;
        _burnAmdTo(owed / 4);
        amd.setPaused(false);

        (,, uint256[] memory amounts) = reserve.previewRedeem(1_000_000e18);
        assertEq(amounts[1], 0, "no AMD for redemptions while the claims are short");
        uint256 carolAmd = amd.balanceOf(carol);
        token.transfer(carol, 1_000_000e18);
        _redeem(carol, 1_000_000e18);
        assertEq(amd.balanceOf(carol), carolAmd);
        assertEq(reserve.claims(address(amd), carol), 0);

        vm.prank(alice);
        reserve.claim(address(amd));
        assertEq(amd.balanceOf(alice), Math.mulDiv(aliceOwed, owed / 4, owed));

        // The keeper buys 1 ETH of AMD (16.67 AMD at the mock prices) through a live target.
        MockVenue venue = new MockVenue(IWETH(address(weth)));
        reserve.queueTarget(address(venue), true);
        vm.warp(block.timestamp + 24 hours); // Tuesday 14:00 UTC, in the purchase window
        _refreshFeeds();
        vm.prank(keeper);
        uint256 bought = reserve.buy(
            address(amd), address(venue), abi.encodeCall(MockVenue.buyAsset, (amd, amdFeed, ethUsd, 1 ether)), 1 ether, 0
        );
        uint256 held = amd.balanceOf(address(reserve));
        assertGt(held, bobOwed, "the buy covers what is still claimed");

        (,, amounts) = reserve.previewRedeem(1_000_000e18);
        assertEq(amounts[1], Math.mulDiv(held - bobOwed, 1_000_000e18 * 9_800, token.totalSupply() * 10_000));
        vm.prank(bob);
        reserve.claim(address(amd));
        assertEq(amd.balanceOf(bob), bobOwed, "paid in full from the refill");
        assertEq(amd.balanceOf(address(reserve)), held - bobOwed);
        assertGt(bought, 0);
    }

    /// A claim reads the Reserve's balance of the asset (with redemption's gas cap) to know whether
    /// it pays in full. While that balance cannot be read the claim reverts and stays recorded.
    function test_a_claim_waits_while_the_balance_cannot_be_read() public {
        HostileToken hostile = _listHostile();
        hostile.setTransferMode(HostileToken.Mode.Revert);
        _redeem(alice, 10_000_000e18);
        assertEq(reserve.claims(address(hostile), alice), 0.98e18);
        hostile.setTransferMode(HostileToken.Mode.Normal);

        hostile.setBalanceMode(HostileToken.Mode.BurnGas);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Reserve.UnreadableAsset.selector, address(hostile)));
        reserve.claim{gas: HOSTILE_GAS}(address(hostile));
        assertEq(reserve.claims(address(hostile), alice), 0.98e18);

        hostile.setBalanceMode(HostileToken.Mode.Normal);
        vm.prank(alice);
        reserve.claim(address(hostile));
        assertEq(hostile.balanceOf(alice), 0.98e18);
    }

    /// Three claims of any size, a burn to any fraction of what they need (or none into them),
    /// collected in any order: each pays its claim times balance / totalClaims at the burn,
    /// rounded down, plus at most a wei for each claim collected before it; the claims take the
    /// whole remaining balance when it is short, and exactly what they are owed when it is not.
    function testFuzz_claims_after_a_burn_each_get_the_same_fraction(
        uint256 a,
        uint256 b,
        uint256 c,
        uint256 leftBps,
        uint256 order
    ) public {
        token.transfer(carol, 10_000_000e18);
        address[3] memory who = [alice, bob, carol];
        uint256[3] memory amount =
            [bound(a, 1, 10_000_000e18), bound(b, 1, 10_000_000e18), bound(c, 1, 10_000_000e18)];
        amd.setPaused(true);
        for (uint256 i; i < 3; ++i) {
            _redeem(who[i], amount[i]);
        }
        uint256 owed = reserve.totalClaims(address(amd));
        vm.assume(owed > 0);
        uint256 left = Math.mulDiv(owed, bound(leftBps, 0, 12_000), 10_000);
        _burnAmdTo(left);
        amd.setPaused(false);

        // One of the six collection orders.
        uint256 first = (order % 6) / 2;
        uint256 second = (first + 1 + order % 2) % 3;
        uint256[3] memory seq = [first, second, 3 - first - second];
        uint256 paidTotal;
        for (uint256 k; k < 3; ++k) {
            address u = who[seq[k]];
            uint256 claimed = reserve.claims(address(amd), u);
            uint256 fair = left >= owed ? claimed : Math.mulDiv(claimed, left, owed);
            if (claimed == 0) continue;
            vm.prank(u);
            reserve.claim(address(amd));
            uint256 got = amd.balanceOf(u);
            assertGe(got, fair);
            assertLe(got, fair + k);
            assertLe(got, claimed);
            paidTotal += got;
        }
        assertEq(reserve.totalClaims(address(amd)), 0);
        assertEq(paidTotal, left >= owed ? owed : left);
        assertEq(amd.balanceOf(address(reserve)), left - paidTotal);
    }

    function test_weth_is_paid_as_eth() public {
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 10 ether}();
        weth.transfer(address(reserve), 10 ether);
        uint256 ethBefore = alice.balance;
        _redeem(alice, 10_000_000e18);
        assertEq(alice.balance - ethBefore, 1.078 ether); // 110 ETH x 0.98%
        assertEq(weth.balanceOf(address(reserve)), 0);
    }

    function test_preview_matches_the_redemption() public {
        (uint256 ethOut, address[] memory tokens, uint256[] memory amounts) = reserve.previewRedeem(10_000_000e18);
        uint256 ethBefore = alice.balance;
        _redeem(alice, 10_000_000e18);
        assertEq(alice.balance - ethBefore, ethOut);
        assertEq(tokens.length, 3);
        for (uint256 i; i < tokens.length; ++i) {
            assertEq(IERC20(tokens[i]).balanceOf(alice), amounts[i]);
        }
    }

    function test_preview_bounds() public {
        vm.expectRevert(Reserve.BadAmount.selector);
        reserve.previewRedeem(0);
        vm.expectRevert(Reserve.BadAmount.selector);
        reserve.previewRedeem(1_000_000_000e18 + 1);
    }

    function test_zero_amount_reverts() public {
        vm.prank(alice);
        vm.expectRevert(Reserve.BadAmount.selector);
        reserve.redeem(0);
    }

    function test_needs_an_allowance() public {
        vm.prank(alice);
        vm.expectRevert();
        reserve.redeem(1e18);
    }

    function testFuzz_backing_per_token_never_falls(uint256 amount) public {
        amount = bound(amount, 1, 10_000_000e18);
        uint256 supplyBefore = token.totalSupply();
        uint256 ethBefore = address(reserve).balance;
        uint256 nvdaBefore = nvda.balanceOf(address(reserve));
        uint256 amdBefore = amd.balanceOf(address(reserve));
        _redeem(alice, amount);
        uint256 supplyAfter = token.totalSupply();
        assertEq(supplyAfter, supplyBefore - amount);
        assertGe(address(reserve).balance * supplyBefore, ethBefore * supplyAfter);
        assertGe(nvda.balanceOf(address(reserve)) * supplyBefore, nvdaBefore * supplyAfter);
        assertGe(amd.balanceOf(address(reserve)) * supplyBefore, amdBefore * supplyAfter);
    }

    function test_pending_asset_is_not_redeemed() public {
        MockStockToken tsm = new MockStockToken("TSM");
        reserve.addAsset(address(tsm), address(new MockFeed(8, 180e8)), 2); // pending for 24 hours
        tsm.mint(address(reserve), 100e18);
        (, address[] memory tokens,) = reserve.previewRedeem(10_000_000e18);
        assertEq(tokens.length, 3);
        _redeem(alice, 10_000_000e18);
        assertEq(tsm.balanceOf(alice), 0);
        assertEq(tsm.balanceOf(address(reserve)), 100e18);
        assertEq(nvda.balanceOf(alice), 9.8e18);
        assertEq(amd.balanceOf(alice), 4.9e18);
    }

    function test_untransferable_token_becomes_a_claim() public {
        BlockableToken blk = new BlockableToken();
        blk.mint(address(reserve), 100e18);
        reserve.addAsset(address(blk), address(new MockFeed(8, 100e8)), 2);
        vm.warp(block.timestamp + 24 hours); // the listing waits a day
        reserve.listAsset(address(blk));
        blk.setBlocked(true);
        _redeem(alice, 10_000_000e18);
        assertEq(nvda.balanceOf(alice), 9.8e18);
        assertEq(amd.balanceOf(alice), 4.9e18);
        assertEq(blk.balanceOf(alice), 0);
        assertEq(reserve.claims(address(blk), alice), 0.98e18);

        blk.setBlocked(false);
        vm.expectEmit(address(reserve));
        emit Reserve.Claimed(alice, address(blk), 0.98e18);
        vm.prank(alice);
        reserve.claim(address(blk));
        assertEq(blk.balanceOf(alice), 0.98e18);
    }
}
