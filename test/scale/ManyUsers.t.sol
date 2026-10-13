// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Vm.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {Reserve} from "../../src/Reserve.sol";
import {Staking} from "../../src/Staking.sol";
import {GatewaySettlement} from "../../src/GatewaySettlement.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IKyzn} from "../../src/interfaces/IKyzn.sol";
import {IRotationState} from "../../src/interfaces/IRotationState.sol";
import {IReserveView} from "../../src/interfaces/IReserveView.sol";
import {Fixture} from "../utils/Fixture.sol";
import {MockFeed} from "../mocks/MockFeed.sol";
import {HostileToken} from "../mocks/HostileToken.sol";

/// Scale review: the Gen 1 contracts under many users (stakers, holders, redeemers) and many
/// transactions, including many in one block.
///
/// Gas figures come from tests run in isolation mode (the inline `isolate = true` setting on
/// each): every call the test makes runs as its own transaction, so each figure is a whole
/// transaction's gas (21,000 base included, refunds deducted) with the cold and warm storage and
/// the zero and non-zero writes a real transaction pays. Gas that grew with the number of users
/// would show as later users paying more than earlier ones; every assertion allows at most 1%.
///
/// The trading tests (3, 4, 5) run on the official Uniswap v2 factory, pair and Router02, deployed
/// offline from their unmodified build artifacts in external/uniswap-v2 (the bytecode
/// the launch tests and the testnet deployment use), so swap-back gas, price impact and
/// pending-tax behaviour are Uniswap's own. The other tests use the fixture's fixed-price mock
/// pool. Nothing here uses a network.
///
/// Tests named test_finding_* pass: each pins down a behaviour the scale review reports (see the
/// comment on each), not a broken invariant. Two findings are fixed (27 September 2026): claims
/// share a shortfall pro-rata (11b) and totalFunded counts each wei once (11).
contract ManyUsersTest is Fixture {
    uint256 internal constant STAKERS = 1_000;
    uint256 internal constant REDEEMERS = 1_000;
    uint256 internal constant TRADERS = 600;

    uint256 internal constant STAKER_BASE = 0x5A_0000_0000;
    uint256 internal constant REDEEMER_BASE = 0x5B_0000_0000;
    uint256 internal constant TRADER_BASE = 0x5C_0000_0000;
    uint256 internal constant DUST_BASE = 0x5D_0000_0000;

    /// Robinhood Chain (Arbitrum Orbit): the review assumes a 32,000,000 block gas limit.
    uint256 internal constant BLOCK_GAS_LIMIT = 32_000_000;
    /// No growth: the last user may pay at most 1% more gas than the first.
    uint256 internal constant FLAT_BPS = 100;

    string internal constant FACTORY_ARTIFACT = "external/uniswap-v2/UniswapV2Factory.json";
    string internal constant ROUTER_ARTIFACT = "external/uniswap-v2/UniswapV2Router02.json";

    /// ETH sent to the fixture's Staking by these tests, from the token as the tax share arrives.
    uint256 internal stakingReceived;

    // ================================================================ helpers

    /// Gas per user for one operation. The first two users can also pay one-time zero-to-non-zero
    /// writes of shared counters (for example Staking's first stake sets totalStaked, the second
    /// its first rewardPerTokenStored and totalAllocated), so the third user is the steady-state
    /// reference.
    struct GasStats {
        uint256 n;
        uint256 first;
        uint256 second;
        uint256 third;
        uint256 last;
        uint256 minSteady; // over the 3rd to the last user
        uint256 maxSteady; // over the 3rd to the last user
    }

    /// The Kyzen Network contracts on the official Uniswap v2 (offline), trading open.
    struct V2 {
        KyznToken token;
        address pair;
        IUniswapV2Router02 router;
        Reserve reserve;
        Staking staking;
        GatewaySettlement gateway;
    }

    struct TradeRun {
        uint256 buys;
        uint256 sells;
        uint256 swaps;
        uint256 taxTaken;
        uint256 taxSold;
        uint256 taxEth;
        uint256 toReserve;
        uint256 toStaking;
        uint256 toDev;
        uint256 maxPending;
        GasStats buy;
        GasStats sellNoSwap;
        GasStats sellSwap;
    }

    function _who(uint256 base, uint256 i) internal pure returns (address) {
        return address(uint160(base + i));
    }

    function _lastGas() internal view returns (uint256) {
        return vm.lastCallGas().gasTotalUsed;
    }

    function _record(GasStats memory s, uint256 gasUsed) internal pure {
        if (s.n == 0) s.first = gasUsed;
        else if (s.n == 1) s.second = gasUsed;
        if (s.n >= 2) {
            if (s.n == 2) {
                s.third = gasUsed;
                s.minSteady = gasUsed;
                s.maxSteady = gasUsed;
            }
            if (gasUsed < s.minSteady) s.minSteady = gasUsed;
            if (gasUsed > s.maxSteady) s.maxSteady = gasUsed;
        }
        s.last = gasUsed;
        ++s.n;
    }

    function _log(string memory name, GasStats memory s) internal pure {
        console2.log(string.concat("gas ", name, ": users / first / second"), s.n, s.first, s.second);
        console2.log(string.concat("gas ", name, ": third / last"), s.third, s.last);
        console2.log(string.concat("gas ", name, ": min / max over users 3..N"), s.minSteady, s.maxSteady);
    }

    /// No gas that grows with the number of users: the last user pays at most 1% more than the
    /// first, and no user from the third on pays more than 1% over the third. (A user may pay less:
    /// the one who empties a shared counter gets a refund, for example.)
    function _assertFlat(string memory name, GasStats memory s) internal pure {
        _log(name, s);
        assertGt(s.n, 2, name);
        assertLe(
            s.last, s.first + s.first * FLAT_BPS / 10_000, string.concat(name, ": last user pays >1% more than first")
        );
        assertLe(
            s.maxSteady,
            s.third + s.third * FLAT_BPS / 10_000,
            string.concat(name, ": a later user pays >1% more than the third")
        );
    }

    function _fundStaking(uint256 amount) internal {
        _taxEthToStaking(amount);
        stakingReceived += amount;
    }

    function _stakeAs(address who, uint256 amount) internal {
        vm.prank(who);
        token.approve(address(staking), amount);
        vm.prank(who);
        staking.stake(amount);
    }

    function _redeemAs(address who, uint256 amount) internal {
        vm.prank(who);
        token.approve(address(reserve), amount);
        vm.prank(who);
        reserve.redeem(amount);
    }

    /// Deploys the official Uniswap v2 factory and Router02 from their build artifacts, and a second
    /// Kyzen Network stack on them: liquidity as SPEC 3.1 (900,000,000 $KYZN with 3 ETH), trading on.
    function _deployRealV2() internal returns (V2 memory s) {
        address factory_ = deployCode(FACTORY_ARTIFACT, abi.encode(address(this)));
        s.router = IUniswapV2Router02(deployCode(ROUTER_ARTIFACT, abi.encode(factory_, address(weth))));
        s.token = new KyznToken(s.router, dev);
        s.pair = s.token.pair();
        s.reserve = new Reserve(
            IKyzn(address(s.token)),
            IWETH(address(weth)),
            address(ethUsd),
            IRotationState(address(registry)),
            new Reserve.AssetConfig[](0)
        );
        s.staking = new Staking(
            IERC20(address(s.token)), s.router, IReserveView(address(s.reserve)), address(nvda), address(amd)
        );
        s.gateway = new GatewaySettlement(IKyzn(address(s.token)), s.router, host);
        s.token.setProtocolAddresses(address(s.reserve), address(s.staking), address(s.gateway));
        s.token.approve(address(s.router), LIQUIDITY_TOKENS);
        s.router.addLiquidityETH{value: 3 ether}(
            address(s.token), LIQUIDITY_TOKENS, 0, 0, address(this), block.timestamp
        );
        s.token.lowerTax(400, 400); // the launch taxes lowered to 4%, as the launch runbook does
    }

    function _v2Buy(V2 memory s, address who, uint256 ethIn) internal returns (uint256 received) {
        vm.deal(who, who.balance + ethIn);
        uint256 before = s.token.balanceOf(who);
        vm.prank(who);
        s.router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            0, _path(address(weth), address(s.token)), who, block.timestamp
        );
        received = s.token.balanceOf(who) - before;
    }

    /// A buy through Router02 that checks the tax: exactly 4% (rounded down) of what left the pool.
    function _v2BuyChecked(V2 memory s, TradeRun memory r, address who, uint256 ethIn) internal {
        uint256 pending = s.token.balanceOf(address(s.token));
        uint256 held = s.token.balanceOf(who);
        vm.deal(who, who.balance + ethIn);
        vm.prank(who);
        s.router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            0, _path(address(weth), address(s.token)), who, block.timestamp
        );
        _record(r.buy, _lastGas());
        uint256 got = s.token.balanceOf(who) - held;
        uint256 tax = s.token.balanceOf(address(s.token)) - pending;
        assertEq(tax, (got + tax) * s.token.buyTaxBps() / 10_000, "buy tax is 4% of what left the pool");
        r.taxTaken += tax;
        ++r.buys;
        if (pending + tax > r.maxPending) r.maxPending = pending + tax;
    }

    struct SellCheck {
        uint256 pending;
        uint256 reserveTokens; // of `pending`, recorded for the Reserve and for Staking
        uint256 stakingTokens;
        uint256 expectSwap;
        uint256 tax;
        uint256 gasUsed;
        uint256 sold;
        uint256 ethIn;
        uint256[3] before; // Reserve, Staking, development ETH
        uint256[3] delta;
    }

    /// A sell through Router02 that checks the swap-back against SPEC 3.1: it runs only at or above
    /// the threshold, sells min(pending, this sell, 0.25% of the pool's $KYZN), and the ETH it
    /// receives (TaxSwapped) pays the Reserve and Staking exactly their recorded shares of what it
    /// sold (2 : 1 : 1 at 4%, to the wei), development the rest, with nothing deferred.
    function _v2SellChecked(V2 memory s, TradeRun memory r, address who, uint256 value) internal {
        SellCheck memory c;
        c.pending = s.token.balanceOf(address(s.token));
        c.expectSwap = c.pending >= s.token.swapThreshold()
            ? Math.min(
                Math.min(c.pending, value), s.token.balanceOf(s.token.pair()) * s.token.SWAP_POOL_BPS() / s.token.BPS()
            )
            : 0;
        c.tax = value * s.token.sellTaxBps() / 10_000;
        c.reserveTokens = s.token.reserveTaxTokens();
        c.stakingTokens = s.token.stakingTaxTokens();
        c.before = [address(s.reserve).balance, address(s.staking).balance, s.token.heldEth(dev)];
        vm.prank(who);
        s.token.approve(address(s.router), value);
        vm.recordLogs();
        vm.prank(who);
        s.router
            .swapExactTokensForETHSupportingFeeOnTransferTokens(
                value, 0, _path(address(s.token), address(weth)), who, block.timestamp
            );
        c.gasUsed = _lastGas();
        bool failed;
        (c.sold, c.ethIn, failed) = _taxSwapFromLogs(address(s.token));
        assertFalse(failed, "a normal sell's swap-back never fails");
        _checkSell(s, c);
        _tallySell(r, c);
    }

    function _checkSell(V2 memory s, SellCheck memory c) internal view {
        assertEq(c.sold, c.expectSwap, "swap-back sells min(pending, sell, pool bound)");
        assertEq(s.token.balanceOf(address(s.token)), c.pending - c.expectSwap + c.tax, "pending tax accounting");
        c.delta[0] = address(s.reserve).balance - c.before[0];
        c.delta[1] = address(s.staking).balance - c.before[1];
        c.delta[2] = s.token.heldEth(dev) - c.before[2]; // held for the development wallet
        assertEq(c.delta[0] + c.delta[1] + c.delta[2], c.ethIn, "every wei of tax ETH is distributed");
        if (c.sold != 0) {
            assertEq(
                c.delta[0], c.ethIn * (c.reserveTokens * c.sold / c.pending) / c.sold, "Reserve: its recorded share"
            );
            assertEq(
                c.delta[1], c.ethIn * (c.stakingTokens * c.sold / c.pending) / c.sold, "Staking: its recorded share"
            );
        }
        assertApproxEqAbs(c.delta[0], c.ethIn / 2, 1, "Reserve gets 2 of 4");
        assertApproxEqAbs(c.delta[1], c.ethIn / 4, 1, "Staking gets 1 of 4");
        assertEq(s.token.totalHeldEth(), s.token.heldEth(dev), "nothing held but development's share");
        assertEq(address(s.token).balance, s.token.totalHeldEth(), "the token keeps only what it holds");
    }

    function _tallySell(TradeRun memory r, SellCheck memory c) internal pure {
        r.taxTaken += c.tax;
        ++r.sells;
        if (c.expectSwap != 0) {
            ++r.swaps;
            r.taxSold += c.sold;
            r.taxEth += c.ethIn;
            r.toReserve += c.delta[0];
            r.toStaking += c.delta[1];
            r.toDev += c.delta[2];
            _record(r.sellSwap, c.gasUsed);
        } else {
            _record(r.sellNoSwap, c.gasUsed);
        }
        if (c.pending + c.tax > r.maxPending) r.maxPending = c.pending + c.tax;
    }

    /// The token's TaxSwapped (tokens sold, ETH received) and whether TaxSwapFailed was emitted.
    function _taxSwapFromLogs(address tokenAddr) internal view returns (uint256 sold, uint256 ethIn, bool failed) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != tokenAddr || logs[i].topics.length == 0) continue;
            if (logs[i].topics[0] == KyznToken.TaxSwapped.selector) {
                (uint256 a, uint256 b) = abi.decode(logs[i].data, (uint256, uint256));
                sold += a;
                ethIn += b;
            } else if (logs[i].topics[0] == KyznToken.TaxSwapFailed.selector) {
                failed = true;
            }
        }
    }

    // ================================================================ 1. 1,000 stakers

    struct StakerRun {
        address[] users;
        uint256[] given;
        uint256[] ethClaimed;
        uint256[] ethCompounded;
        uint256[] kyznCompounded;
        GasStats stake;
        GasStats claimEth;
        GasStats claimCompound;
        GasStats unstake; // the 900 whose wallet was empty (everything staked)
        GasStats unstakeTopUp; // the 100 that took half out mid-stream: the wallet already holds $KYZN
    }

    /// 1,000 stakers join one second apart during a live stream, are funded twice, claim in both
    /// payout modes (the first 500 in ETH, the last 500 by Compound), a tenth unstake half mid-stream,
    /// and all unstake. Gas per stake, claim and unstake does not grow with the number of stakers;
    /// every wei paid is one staker's; stakers are paid all the funded ETH but rounding dust, and no
    /// $KYZN is lost or created.
    /// forge-config: default.isolate = true
    function test_scale_1000_stakers_are_funded_claim_in_both_modes_and_unstake() public {
        _launch();
        token.removeMaxWallet();
        StakerRun memory r;
        r.users = new address[](STAKERS);
        r.given = new uint256[](STAKERS);
        r.ethClaimed = new uint256[](STAKERS);
        r.ethCompounded = new uint256[](STAKERS);
        r.kyznCompounded = new uint256[](STAKERS);
        for (uint256 i; i < STAKERS; ++i) {
            r.users[i] = _who(STAKER_BASE, i);
        }

        // Day 1: 0.5 ETH is funded before anyone stakes; the 1,000 join one second apart.
        _fundStaking(0.5 ether);
        staking.notifyRewards();
        uint256 day1 = block.timestamp;
        _stakeAll(r);
        assertEq(staking.totalStaked(), _sum(r.given));

        // Twelve hours in: the first 500 claim ETH, the last 500 compound.
        vm.warp(day1 + 12 hours);
        _claimAll(r, true);

        // Day 2: 0.3 ETH more; six hours in, every tenth staker takes half its stake out.
        vm.warp(day1 + 24 hours);
        _fundStaking(0.3 ether);
        staking.notifyRewards();
        vm.warp(block.timestamp + 6 hours);
        _halfUnstakes(r);

        // After day 2: everyone claims the rest in its mode, then unstakes everything.
        vm.warp(day1 + 48 hours + 1);
        _claimAll(r, false);
        _unstakeAll(r);

        _assertStakingConserved(r);
        _assertFlat("stake", r.stake);
        _assertFlat("claim (ETH)", r.claimEth);
        _assertFlat("claimCompound", r.claimCompound);
        _assertFlat("unstake all, empty wallet", r.unstake);
        _assertFlat("unstake all, wallet holds $KYZN", r.unstakeTopUp);
    }

    function _sum(uint256[] memory a) internal pure returns (uint256 total) {
        for (uint256 i; i < a.length; ++i) {
            total += a[i];
        }
    }

    function _stakeAll(StakerRun memory r) internal {
        for (uint256 i; i < r.users.length; ++i) {
            vm.warp(block.timestamp + 1);
            address u = r.users[i];
            uint256 amount = 10_000e18 + i * 1e18 + i;
            r.given[i] = amount;
            token.transfer(u, amount);
            vm.prank(u);
            token.approve(address(staking), amount);
            vm.prank(u);
            staking.stake(amount);
            _record(r.stake, _lastGas());
            assertEq(staking.stakedOf(u), amount);
        }
    }

    function _claimAll(StakerRun memory r, bool measure) internal {
        uint256 half = r.users.length / 2;
        for (uint256 i; i < r.users.length; ++i) {
            vm.warp(block.timestamp + 1);
            uint256 owed = staking.earned(r.users[i]);
            assertGt(owed, 0, "every staker has earned something");
            if (i < half) _claimEthOne(r, i, owed, measure);
            else _claimCompoundOne(r, i, owed, measure);
            assertEq(staking.earned(r.users[i]), 0);
        }
    }

    function _claimEthOne(StakerRun memory r, uint256 i, uint256 owed, bool measure) internal {
        address u = r.users[i];
        uint256 balanceBefore = u.balance;
        vm.prank(u);
        uint256 amount = staking.claim();
        if (measure) _record(r.claimEth, _lastGas());
        assertEq(u.balance - balanceBefore, amount);
        assertEq(amount, owed, "claim pays what earned() showed");
        r.ethClaimed[i] += amount;
    }

    function _claimCompoundOne(StakerRun memory r, uint256 i, uint256 owed, bool measure) internal {
        address u = r.users[i];
        if (staking.payoutMode(u) != Staking.PayoutMode.Compound) {
            vm.prank(u);
            staking.setPayoutMode(Staking.PayoutMode.Compound);
        }
        uint256 paidBefore = staking.totalPaid();
        uint256 stakedBefore = staking.stakedOf(u);
        vm.prank(u);
        uint256 added = staking.claimCompound(0);
        if (measure) _record(r.claimCompound, _lastGas());
        uint256 spent = staking.totalPaid() - paidBefore;
        assertEq(spent, owed, "compound spends what earned() showed");
        assertEq(added, spent * router.TOKENS_PER_ETH(), "compound buys untaxed");
        assertEq(staking.stakedOf(u), stakedBefore + added);
        r.ethCompounded[i] += spent;
        r.kyznCompounded[i] += added;
    }

    function _halfUnstakes(StakerRun memory r) internal {
        for (uint256 i; i < r.users.length; i += 10) {
            vm.warp(block.timestamp + 1);
            address u = r.users[i];
            uint256 half = staking.stakedOf(u) / 2;
            vm.prank(u);
            staking.withdraw(half);
        }
    }

    function _unstakeAll(StakerRun memory r) internal {
        for (uint256 i; i < r.users.length; ++i) {
            address u = r.users[i];
            uint256 amount = staking.stakedOf(u);
            vm.prank(u);
            staking.withdraw(amount);
            // Sending $KYZN into an empty wallet costs a zero-to-non-zero write the others skip.
            _record(i % 10 == 0 ? r.unstakeTopUp : r.unstake, _lastGas());
            assertEq(staking.stakedOf(u), 0);
            assertEq(token.balanceOf(u), r.given[i] + r.kyznCompounded[i], "no $KYZN lost or created in Staking");
        }
    }

    function _assertStakingConserved(StakerRun memory r) internal view {
        uint256 paid;
        for (uint256 i; i < r.users.length; ++i) {
            paid += r.ethClaimed[i] + r.ethCompounded[i];
            assertEq(staking.earned(r.users[i]), 0);
        }
        assertEq(paid, staking.totalPaid(), "every wei paid went to a staker");
        assertLe(staking.totalPaid(), staking.totalAllocated(), "paid <= allocated");
        assertLe(staking.totalAllocated(), stakingReceived, "allocated <= ETH received");
        assertLe(staking.totalPaid(), staking.totalFunded(), "paid <= funded");
        // Day 1's first second, before anyone staked, streamed to nobody and rolled into day 2:
        // counted once, so funded stays within the ETH received.
        assertLe(staking.totalFunded(), stakingReceived, "funded <= ETH received");
        assertEq(address(staking).balance, stakingReceived - paid, "ETH conserved");
        assertEq(staking.totalStaked(), 0);
        assertEq(token.balanceOf(address(staking)), 0, "every staked $KYZN went back");
        uint256 unpaid = stakingReceived - paid;
        uint256 stuckDust = staking.totalAllocated() - staking.totalPaid();
        console2.log("stakers: ETH received / paid to stakers", stakingReceived, paid);
        console2.log(
            "stakers: unpaid wei (rolls into next funding) / allocated-but-unclaimable dust",
            unpaid - stuckDust,
            stuckDust
        );
        // What stakers did not get: under 86,400 wei of the last funding's remainder plus at most a
        // wei per checkpoint; 1e-13 ETH on 0.8 ETH.
        assertLt(unpaid, 86_400 + 10 * STAKERS, "stakers received all but rounding dust");
    }

    // ================================================================ 2. 1,000 redemptions

    struct RedeemRun {
        uint256 supply0;
        uint256 eth0;
        uint256[3] asset0;
        uint256 burned;
        uint256 ethPaid;
        uint256[3] assetOut; // paid or recorded as a claim
        uint256 amdClaims;
        GasStats redeem;
        GasStats redeemPaused;
        GasStats claim;
    }

    /// 1,000 holders redeem one after another against a Reserve holding ETH, NVDA, AMD and MU; AMD's
    /// issuer pauses it for redeemers 400 to 599, whose AMD is recorded as claims and collected
    /// after the unpause. Every payout equals previewRedeem and the exact pro-rata formula; the
    /// Reserve pays out exactly what it loses and backing per token never falls; supply falls only
    /// by the burns; redeem and claim gas do not grow with the number of redeemers.
    /// forge-config: default.isolate = true
    function test_scale_1000_redemptions_pay_exact_shares_with_flat_gas() public {
        _launch();
        token.removeMaxWallet();
        vm.deal(address(reserve), 40 ether);
        nvda.mint(address(reserve), 1_000e18);
        amd.mint(address(reserve), 2_000e18);
        mu.mint(address(reserve), 3_000e18);

        RedeemRun memory r;
        r.supply0 = token.totalSupply();
        r.eth0 = address(reserve).balance;
        r.asset0 = [nvda.balanceOf(address(reserve)), amd.balanceOf(address(reserve)), mu.balanceOf(address(reserve))];

        for (uint256 i; i < REDEEMERS; ++i) {
            if (i == 400) amd.setPaused(true);
            if (i == 600) amd.setPaused(false);
            _redeemOne(r, i);
        }
        for (uint256 i = 400; i < 600; ++i) {
            address u = _who(REDEEMER_BASE, i);
            uint256 owed = reserve.claims(address(amd), u);
            vm.prank(u);
            reserve.claim(address(amd));
            _record(r.claim, _lastGas());
            assertEq(amd.balanceOf(u), owed);
        }
        assertEq(reserve.totalClaims(address(amd)), 0, "every claim collected");

        _assertRedemptionsConserved(r);
        _assertFlat("redeem (3 assets + ETH)", r.redeem);
        _assertFlat("redeem with AMD paused (claim recorded)", r.redeemPaused);
        _assertFlat("claim(AMD) after unpause", r.claim);
    }

    function _redeemOne(RedeemRun memory r, uint256 i) internal {
        address u = _who(REDEEMER_BASE, i);
        uint256 amount = 20_000e18 + i * 1e18 + i;
        token.transfer(u, amount);
        vm.prank(u);
        token.approve(address(reserve), amount);
        (uint256 ethOut,, uint256[] memory amounts) = reserve.previewRedeem(amount);
        uint256 supplyBefore = token.totalSupply();
        uint256 ethHeld = address(reserve).balance;
        bool paused = amd.paused();
        vm.prank(u);
        reserve.redeem(amount);
        if (paused) _record(r.redeemPaused, _lastGas());
        else _record(r.redeem, _lastGas());

        assertEq(ethOut, Math.mulDiv(ethHeld, amount * 9_800, supplyBefore * 10_000), "exact pro-rata ETH");
        assertEq(u.balance, ethOut);
        assertEq(nvda.balanceOf(u), amounts[0]);
        assertEq(mu.balanceOf(u), amounts[2]);
        if (paused) {
            assertEq(amd.balanceOf(u), 0);
            assertEq(reserve.claims(address(amd), u), amounts[1], "paused share recorded as a claim");
            r.amdClaims += amounts[1];
        } else {
            assertEq(amd.balanceOf(u), amounts[1]);
        }
        assertEq(token.totalSupply(), supplyBefore - amount, "supply falls by the burn");
        r.burned += amount;
        r.ethPaid += ethOut;
        for (uint256 k; k < 3; ++k) {
            r.assetOut[k] += amounts[k];
        }
    }

    function _assertRedemptionsConserved(RedeemRun memory r) internal view {
        uint256 supply = token.totalSupply();
        assertEq(r.supply0 - supply, r.burned, "supply fell only by the redemptions' burns");
        uint256 ethLeft = address(reserve).balance;
        assertEq(r.eth0 - ethLeft, r.ethPaid, "the Reserve paid exactly what it lost");
        // Backing per remaining token never falls: left / supply >= start / supply0.
        assertGe(ethLeft * r.supply0, r.eth0 * supply, "ETH backing per token did not fall");
        uint256[3] memory left =
            [nvda.balanceOf(address(reserve)), amd.balanceOf(address(reserve)), mu.balanceOf(address(reserve))];
        for (uint256 k; k < 3; ++k) {
            assertEq(r.asset0[k] - left[k], r.assetOut[k], "asset paid or claimed exactly");
            assertGe(left[k] * r.supply0, r.asset0[k] * supply, "asset backing per token did not fall");
        }
        console2.log("redemptions: $KYZN burned / ETH paid (wei)", r.burned, r.ethPaid);
        console2.log("redemptions: AMD recorded as claims while paused", r.amdClaims);
        console2.log(
            "redemptions: ETH a pure pro-rata split would have paid more",
            Math.mulDiv(r.eth0, r.burned, r.supply0) - r.ethPaid
        );
    }

    // ================================================================ 3. 600 holders on Uniswap v2

    /// 600 holders buy through the official Uniswap v2 Router02 one after another, and each sells
    /// half of its $KYZN once the next has bought, so the pending tax crosses the threshold again and
    /// again and the swap-back runs dozens of times. Every buy and sell is checked against SPEC 3.1
    /// (see _v2BuyChecked and _v2SellChecked); no $KYZN is created or lost; the tax ETH reaches its
    /// three recipients in full; buy and sell gas do not grow with the number of holders.
    /// forge-config: default.isolate = true
    function test_scale_600_holders_trade_on_uniswap_v2_and_swap_back_repeats() public {
        V2 memory s = _deployRealV2();
        s.token.removeMaxWallet();
        TradeRun memory r;
        address[] memory traders = new address[](TRADERS);
        for (uint256 i; i < TRADERS; ++i) {
            vm.warp(block.timestamp + 12); // a trade every 12 seconds
            traders[i] = _who(TRADER_BASE, i);
            uint256 ethIn = i % 50 == 49 ? 0.03 ether : 0.001 ether + (i % 10) * 0.0005 ether;
            _v2BuyChecked(s, r, traders[i], ethIn);
            if (i != 0) {
                address seller = traders[i - 1];
                _v2SellChecked(s, r, seller, s.token.balanceOf(seller) / 2);
            }
        }
        _v2SellChecked(s, r, traders[TRADERS - 1], s.token.balanceOf(traders[TRADERS - 1]) / 2);

        // $KYZN: nothing created or lost; supply unchanged (trading burns nothing).
        uint256 held =
            s.token.balanceOf(s.pair) + s.token.balanceOf(address(s.token)) + s.token.balanceOf(address(this));
        for (uint256 i; i < TRADERS; ++i) {
            held += s.token.balanceOf(traders[i]);
        }
        assertEq(held, s.token.INITIAL_SUPPLY(), "every $KYZN accounted for");
        assertEq(s.token.totalSupply(), s.token.INITIAL_SUPPLY());
        // Tax: what was taken is either sold by a swap-back or still pending.
        assertEq(r.taxTaken, r.taxSold + s.token.balanceOf(address(s.token)), "tax taken = sold + pending");
        // Tax ETH: all of it reached the three recipients, 2 : 1 : 1.
        assertEq(r.toReserve + r.toStaking + r.toDev, r.taxEth);
        assertEq(address(s.reserve).balance, r.toReserve);
        assertEq(address(s.staking).balance, r.toStaking);
        assertGe(r.swaps, 50, "swap-back ran again and again");

        console2.log("trading: buys / sells / swap-backs", r.buys, r.sells, r.swaps);
        console2.log(
            "trading: tax taken / tax sold / still pending ($KYZN wei)",
            r.taxTaken,
            r.taxSold,
            s.token.balanceOf(address(s.token))
        );
        console2.log("trading: tax ETH / to Reserve / to Staking", r.taxEth, r.toReserve, r.toStaking);
        console2.log("trading: highest pending tax ($KYZN wei)", r.maxPending);
        _assertFlat("buy via Router02", r.buy);
        _assertFlat("sell via Router02, no swap-back", r.sellNoSwap);
        _assertFlat("sell via Router02 with swap-back", r.sellSwap);
        console2.log("trading: swap-back adds (gas, steady state)", r.sellSwap.third - r.sellNoSwap.third);

        // The Staking share streams as usual.
        s.staking.notifyRewards();
        assertEq(s.staking.lastFundingAmount(), r.toStaking / 1 days * 1 days);
    }

    // ================================================================ 4. many sells in one block

    /// A crowd of sellers in one block while the pending tax is far above any one sell: each sell
    /// runs its own swap-back of min(pending, its size), in order, until the pending tax is back
    /// under the threshold; none reverts and every ETH split is exact (_v2SellChecked).
    function test_same_block_sells_each_run_their_own_bounded_swap_back() public {
        V2 memory s = _deployRealV2();
        s.token.removeMaxWallet();
        address[] memory crowd = new address[](10);
        for (uint256 i; i < crowd.length; ++i) {
            crowd[i] = _who(TRADER_BASE, i);
            vm.warp(block.timestamp + 1);
            _v2Buy(s, crowd[i], 0.1 ether);
        }
        uint256 pending = s.token.balanceOf(address(s.token));
        assertGt(pending, 2 * 3_000_000e18, "pending tax above two sells");

        TradeRun memory r;
        uint256 blockNumber = block.number;
        uint256 time = block.timestamp;
        for (uint256 i; i < crowd.length; ++i) {
            _v2SellChecked(s, r, crowd[i], 3_000_000e18);
        }
        assertEq(block.number, blockNumber);
        assertEq(block.timestamp, time);
        assertGe(r.swaps, 4, "each seller ran a swap-back");
        assertLt(s.token.balanceOf(address(s.token)), s.token.swapThreshold() + 120_000e18);
        console2.log("same block: pending before / swap-backs / tax sold", pending, r.swaps, r.taxSold);
    }

    /// Dust against the official Router02: a 1-wei sell through the router reverts on its own
    /// (Uniswap pays zero out), and 100 one-wei transfers straight into the pair each try a 1-wei
    /// swap-back that Uniswap refuses, caught as TaxSwapFailed, with the pending tax untouched. The
    /// next ordinary sell runs its full swap-back as usual.
    function test_dust_sells_on_uniswap_v2_fail_alone() public {
        V2 memory s = _deployRealV2();
        s.token.removeMaxWallet();
        address trader = _who(TRADER_BASE, 0);
        _v2Buy(s, trader, 0.05 ether); // tax above the threshold
        uint256 pending = s.token.balanceOf(address(s.token));
        assertGe(pending, s.token.swapThreshold());

        address duster = makeAddr("duster");
        vm.prank(trader);
        s.token.transfer(duster, 1_000);
        vm.prank(duster);
        s.token.approve(address(s.router), 1);
        address[] memory path = _path(address(s.token), address(weth));
        vm.prank(duster);
        vm.expectRevert(bytes("UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT"));
        s.router.swapExactTokensForETHSupportingFeeOnTransferTokens(1, 0, path, duster, block.timestamp);

        for (uint256 i; i < 100; ++i) {
            vm.expectEmit(address(s.token));
            emit KyznToken.TaxSwapFailed(1);
            vm.prank(duster);
            s.token.transfer(s.pair, 1);
        }
        assertEq(s.token.balanceOf(address(s.token)), pending, "dust never moved the pending tax");

        TradeRun memory r;
        _v2SellChecked(s, r, trader, 1_000_000e18);
        assertEq(r.swaps, 1);
        assertEq(r.taxSold, Math.min(pending, 1_000_000e18));
    }

    /// 300 equal stakers stake in one block, and after the day all 300 claim in one block: every
    /// claim is the same to the wei, and together they never exceed what streamed.
    function test_many_stakes_and_claims_in_one_block_get_equal_shares() public {
        _launch();
        token.removeMaxWallet();
        for (uint256 i; i < 300; ++i) {
            address u = _who(STAKER_BASE, i);
            token.transfer(u, 1_000e18);
            _stakeAs(u, 1_000e18);
        }
        _fundStaking(1 ether);
        staking.notifyRewards();
        uint256 streamed = staking.lastFundingAmount();
        vm.warp(block.timestamp + 1 days);
        uint256 first;
        uint256 total;
        for (uint256 i; i < 300; ++i) {
            vm.prank(_who(STAKER_BASE, i));
            uint256 paid = staking.claim();
            if (i == 0) first = paid;
            assertEq(paid, first, "equal stakes, equal pay");
            total += paid;
        }
        assertLe(total, streamed);
        assertApproxEqAbs(first, streamed / 300, 1);
        console2.log("300 claims in one block: each / together / streamed (wei)", first, total, streamed);
    }

    // ================================================================ 5. finding: gas of an unexpected swap-back

    /// FINDING (Important for UX under load; no funds at risk, no contract state affected).
    /// Whether a sell runs the swap-back depends on the pending tax when it executes, not when the
    /// wallet estimated its gas. A sell estimated while the pending tax is below the threshold, and
    /// mined after other trades pushed it over, also pays for the swap-back (Router02 swap, WETH
    /// unwrap, three ETH sends): here the least gas limit goes from about 136,000 to about 284,000,
    /// more than double. With the estimate plus 50% the sell runs out of gas and reverts whole: the
    /// try/catch around the swap-back cannot save it, since the catch runs on the 1/64 of gas the
    /// failed call leaves. The seller keeps its tokens and loses the gas fee; a re-estimated retry
    /// succeeds. The busier the pool, the more often a sell lands just after a crossing. Steady
    /// state (the swap-back has run before, so no first-time costs); isolation mode, so the limits
    /// are whole-transaction limits as eth_estimateGas reports them.
    /// Mitigation without a contract change: every sell the Kyzen app builds gets a fixed extra
    /// gas allowance for the swap-back (about 150,000 plus margin; unused gas is not charged), and
    /// the integration notes tell aggregators and wallets the same.
    /// forge-config: default.isolate = true
    function test_finding_a_sell_estimated_below_the_threshold_can_run_out_of_gas_above_it() public {
        V2 memory s = _deployRealV2();
        s.token.removeMaxWallet();
        address warmup = _who(TRADER_BASE, 9);
        _v2Buy(s, warmup, 0.05 ether); // tax above the threshold
        vm.prank(warmup);
        s.token.approve(address(s.router), type(uint256).max);
        _trySell(s, warmup, 1_000_000e18, 5_000_000); // the first swap-back has run
        vm.warp(block.timestamp + 12);

        address seller = _who(TRADER_BASE, 0);
        _v2Buy(s, seller, 0.01 ether);
        assertLt(s.token.balanceOf(address(s.token)), s.token.swapThreshold());
        uint256 amount = 1_000_000e18;
        vm.prank(seller);
        s.token.approve(address(s.router), type(uint256).max);

        // Below the threshold: the least gas the sell needs, as eth_estimateGas finds it.
        uint256 before = vm.snapshotState();
        uint256 estimate = _minSellGas(s, seller, amount);

        // Other trades in the meantime push the pending tax over the threshold.
        _v2Buy(s, _who(TRADER_BASE, 1), 0.04 ether);
        assertGe(s.token.balanceOf(address(s.token)), s.token.swapThreshold());
        uint256 needed = _minSellGas(s, seller, amount);
        uint256 withMargin = estimate * 3 / 2;
        console2.log(
            "sell, least gas for the call: no swap-back due / swap-back due / estimate + 50%",
            estimate,
            needed,
            withMargin
        );
        console2.log(
            "  swap-back adds (gas) / as a share of the estimate (bps)",
            needed - estimate,
            (needed - estimate) * 10_000 / estimate
        );
        assertGt(needed, withMargin, "a 50% margin does not cover the swap-back");

        // The sell with the estimate plus 50%: runs out of gas now; fit before the other trades.
        assertFalse(_trySell(s, seller, amount, withMargin), "out of gas once the swap-back is due");
        vm.revertToState(before);
        assertTrue(_trySell(s, seller, amount, withMargin), "fits while no swap-back is due");
    }

    /// Binary search for the least gas the sell succeeds with, the way eth_estimateGas works;
    /// every attempt is rolled back.
    function _minSellGas(V2 memory s, address who, uint256 amount) internal returns (uint256 hi) {
        uint256 lo = 30_000;
        hi = 3_000_000;
        while (hi - lo > 100) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            bool ok = _trySell(s, who, amount, mid);
            vm.revertToStateAndDelete(snap);
            if (ok) hi = mid;
            else lo = mid;
        }
    }

    /// Sells with the given gas for the router call, every account it touches cold.
    function _trySell(V2 memory s, address who, uint256 amount, uint256 gasLimit) internal returns (bool ok) {
        address[8] memory touched = [
            address(s.token), s.pair, address(s.router), address(weth), who, address(s.reserve), address(s.staking), dev
        ];
        for (uint256 i; i < touched.length; ++i) {
            vm.cool(touched[i]);
        }
        address[] memory path = _path(address(s.token), address(weth));
        vm.prank(who);
        try s.router.swapExactTokensForETHSupportingFeeOnTransferTokens{gas: gasLimit}(
            amount, 0, path, who, block.timestamp
        ) {
            ok = true;
        } catch {
            ok = false;
        }
    }

    // ================================================================ 6. max wallet with a crowd

    /// While the max wallet is on, 300 buyers in one block each stay under 2% and none is blocked by
    /// the others; a buy that would take one wallet over 2% reverts for that wallet only. The limit
    /// holds buys from the pool: wallet transfers and unstaking are not limited. Once the owner
    /// removes it, a buy above 2% goes through.
    function test_max_wallet_binds_each_buyer_of_a_crowd_until_removed() public {
        _launch();
        uint256 cap = token.MAX_WALLET();
        for (uint256 i; i < 250; ++i) {
            address b = _who(TRADER_BASE, i);
            _buy(b, 0.004 ether); // 1,200,000 from the pool, 1,152,000 after tax
            assertLe(token.balanceOf(b), cap);
        }
        address whale = makeAddr("whale");
        _buy(whale, 0.066 ether); // 19,008,000 after tax
        assertLe(token.balanceOf(whale), cap);

        vm.deal(whale, 0.004 ether);
        vm.prank(whale);
        vm.expectRevert(KyznToken.MaxWalletExceeded.selector);
        router.swapExactETHForTokensSupportingFeeOnTransferTokens{value: 0.004 ether}(
            0, _path(address(weth), address(token)), whale, block.timestamp
        );

        // The rest of the crowd is unaffected, in the same block.
        for (uint256 i = 250; i < 300; ++i) {
            _buy(_who(TRADER_BASE, i), 0.004 ether);
        }

        // Wallet transfers and unstaking are not limited.
        address buyer0 = _who(TRADER_BASE, 0);
        vm.prank(buyer0);
        token.transfer(whale, 1_152_000e18);
        assertGt(token.balanceOf(whale), cap);
        _stakeAs(whale, token.balanceOf(whale));
        uint256 staked = staking.stakedOf(whale);
        vm.prank(whale);
        staking.withdraw(staked);
        assertGt(token.balanceOf(whale), cap);

        token.removeMaxWallet();
        assertFalse(token.maxWalletActive());
        _buy(whale, 0.004 ether);
        assertGt(token.balanceOf(whale), cap + 1_000_000e18);
    }

    // ================================================================ 7. precision: staking

    struct PrecisionRun {
        address[5] who; // whale, this contract, mid (1,000,000), tiny (1 $KYZN), dust (1 wei)
        uint256 total;
        uint256 cumStreamed;
    }

    /// About 9.35e26 wei-tokens staked (935,200,000 $KYZN, 93.5% of supply) and fundings from
    /// 86,400 wei to 1 ETH: every staker, down to 1 wei of stake, earns its exact pro-rata share of
    /// what streamed, within 1 wei a day and never above it over the whole run. PRECISION = 1e36
    /// leaves rewardPerToken ~1.07e9 units per wei-per-second of rate even at this total stake. A
    /// funding under 86,400 wei streams nothing (the rate rounds to 0) and waits for the next day;
    /// 1,000 checkpoints in one day allocate exactly what streamed.
    function test_precision_rewards_with_935M_staked_and_tiny_fundings() public {
        _launch();
        token.removeMaxWallet();
        PrecisionRun memory p = _precisionStakers();
        assertEq(p.total, 935_200_000e18 - 10_000);

        // Below 86,400 wei the rate rounds to zero: nothing streams, the ETH waits.
        _fundStaking(86_399);
        staking.notifyRewards();
        assertEq(staking.rewardRate(), 0);
        assertEq(staking.lastFundingAmount(), 0);
        vm.warp(block.timestamp + 1 days);
        assertEq(staking.earned(p.who[0]), 0, "nothing streamed");
        // One more wei makes 86,400: 1 wei per second, the smallest rate there is.
        _checkOneDay(p, 1);
        assertEq(staking.rewardRate(), 1);

        uint256[4] memory fundings = [uint256(1e9), 1e12, 1e15, 1e18];
        for (uint256 d; d < fundings.length; ++d) {
            _checkOneDay(p, fundings[d]);
        }
        for (uint256 k; k < 5; ++k) {
            uint256 exact = Math.mulDiv(p.cumStreamed, staking.stakedOf(p.who[k]), p.total);
            uint256 got = staking.earned(p.who[k]);
            assertLe(got, exact, "over the run, never above the exact share");
            assertLe(exact - got, 1, "over the run, at most 1 wei below it");
        }
        assertEq(address(staking).balance, stakingReceived - staking.totalPaid());
        _checkManyCheckpoints(p);
    }

    function _precisionStakers() internal returns (PrecisionRun memory p) {
        p.who = [makeAddr("whale"), address(this), makeAddr("mid"), makeAddr("tiny"), makeAddr("dust")];
        _buy(p.who[0], 2.9 ether); // 870,000,000 from the pool, 835,200,000 after tax
        token.transfer(p.who[2], 1_000_000e18 + 10_000);
        token.transfer(p.who[3], 1e18);
        token.transfer(p.who[4], 1);
        _stakeAs(p.who[0], token.balanceOf(p.who[0]));
        _stakeAs(p.who[2], 1_000_000e18);
        _stakeAs(p.who[3], 1e18);
        _stakeAs(p.who[4], 1);
        token.approve(address(staking), token.balanceOf(address(this)));
        staking.stake(token.balanceOf(address(this)));
        p.total = staking.totalStaked();
    }

    function _checkOneDay(PrecisionRun memory p, uint256 funding) internal {
        uint256[5] memory before;
        for (uint256 k; k < 5; ++k) {
            before[k] = staking.earned(p.who[k]);
        }
        if (block.timestamp < staking.nextFundingAt()) vm.warp(staking.nextFundingAt());
        _fundStaking(funding);
        staking.notifyRewards();
        uint256 streamed = staking.lastFundingAmount();
        p.cumStreamed += streamed;
        uint256 rpt0 = staking.rewardPerToken();
        vm.warp(block.timestamp + 1 days);
        uint256 maxGap = _dayGap(p, before, streamed);
        console2.log(
            "funding (wei) / streamed / rewardPerToken growth per second",
            funding,
            streamed,
            (staking.rewardPerToken() - rpt0) / 1 days
        );
        console2.log(
            "  largest gap to exact share (wei) / 1 $KYZN staker earned / 1-wei staker earned",
            maxGap,
            staking.earned(p.who[3]) - before[3],
            staking.earned(p.who[4]) - before[4]
        );
    }

    /// Each staker's earnings for the day against its exact share, floor(streamed x stake / total):
    /// within 1 wei. A day can carry a wei of the previous days' fractions, so the day's total may
    /// top what streamed that day by at most a wei per staker; over the whole run it never does
    /// (checked in the test).
    function _dayGap(PrecisionRun memory p, uint256[5] memory before, uint256 streamed)
        internal
        view
        returns (uint256 maxGap)
    {
        uint256 sum;
        for (uint256 k; k < 5; ++k) {
            uint256 got = staking.earned(p.who[k]) - before[k];
            uint256 exact = Math.mulDiv(streamed, staking.stakedOf(p.who[k]), p.total);
            uint256 gap = got > exact ? got - exact : exact - got;
            assertLe(gap, 1, "within 1 wei of the exact share");
            if (gap > maxGap) maxGap = gap;
            sum += got;
        }
        assertLe(sum, streamed + 5, "a day's earnings top its stream by at most a carried wei each");
    }

    /// 1,000 checkpoints in one day (a stake every 86 seconds): allocation never exceeds what streamed.
    function _checkManyCheckpoints(PrecisionRun memory p) internal {
        address mid = p.who[2];
        vm.warp(staking.nextFundingAt());
        _fundStaking(1e15);
        staking.notifyRewards();
        uint256 streamed = staking.lastFundingAmount();
        uint256 allocated0 = staking.totalAllocated();
        vm.prank(mid);
        token.approve(address(staking), type(uint256).max);
        for (uint256 i; i < 1_000; ++i) {
            vm.warp(block.timestamp + 86);
            vm.prank(mid);
            staking.stake(1);
        }
        vm.warp(block.timestamp + 1 days);
        vm.prank(mid);
        staking.stake(1);
        uint256 allocated = staking.totalAllocated() - allocated0;
        console2.log("1,000 checkpoints in a day: streamed / allocated (wei)", streamed, allocated);
        assertLe(allocated, streamed);
        assertLe(streamed - allocated, 1_001);
    }

    // ================================================================ 8. precision: redemption

    /// Redemption at full supply (1e27): 1 $KYZN of 1,000,000,000 against 1 ETH pays exactly
    /// 980,000,000 wei; 1 wei of $KYZN pays 0 and still burns (rounding always favours the Reserve,
    /// by under 1 wei per asset). Split redemptions: a 9% holder redeeming in 100 pieces instead of
    /// one receives slightly more, because each piece's 2% stays in the Reserve and partly backs the
    /// holder's own remaining pieces. Inherent to SPEC 3.2's formula (pro-rata of total supply, 2%
    /// kept); never more than the Reserve holds. The difference is logged.
    function test_precision_redemption_at_full_supply_and_split_redemptions() public {
        _launch();
        token.removeMaxWallet();
        vm.deal(address(reserve), 1 ether);
        address one = makeAddr("one");
        token.transfer(one, 1e18 + 1);
        _redeemAs(one, 1e18);
        assertEq(one.balance, 980_000_000, "1 $KYZN of 1e9 x 1 ETH x 98%");
        uint256 supply = token.totalSupply();
        _redeemAs(one, 1);
        assertEq(one.balance, 980_000_000, "1 wei of $KYZN pays nothing");
        assertEq(token.totalSupply(), supply - 1, "and still burns");

        uint256 whole = 90_000_000e18; // 9% of supply
        uint256 held = address(reserve).balance;
        token.approve(address(reserve), whole);
        uint256 snap = vm.snapshotState();
        uint256 before = address(this).balance;
        reserve.redeem(whole);
        uint256 single = address(this).balance - before;
        vm.revertToState(snap);
        before = address(this).balance;
        for (uint256 i; i < 100; ++i) {
            reserve.redeem(whole / 100);
        }
        uint256 split = address(this).balance - before;
        console2.log(
            "9% holder: one redemption / 100 pieces / extra from splitting (wei)", single, split, split - single
        );
        console2.log(
            "  fee paid, one redemption vs 100 pieces (wei)",
            Math.mulDiv(held, whole, supply) - single,
            Math.mulDiv(held, whole, supply) - split
        );
        assertGe(split, single);
        assertLe(split - single, single / 500, "splitting recovers under 0.2% of the payout");
        assertLt(split, held, "never more than the Reserve holds");
    }

    // ================================================================ 9. dust crowd

    /// 1,000 one-wei stakers, 200 one-wei sells while the pending tax is above the threshold and
    /// 1,000 one-wei redemptions: nobody else's gas, rewards, swap-back or payout changes beyond
    /// the dust itself. Dust positions earn their exact (zero) share, dust sells swap back only their
    /// own size, dust redemptions pay nothing and burn.
    /// forge-config: default.isolate = true
    function test_dust_crowd_changes_nothing_for_others() public {
        _launch();
        token.removeMaxWallet();
        _dustStakers();
        _dustSells();
        _dustRedemptions();
    }

    function _dustStakers() internal {
        token.transfer(alice, 1_000_000e18);
        _stakeAs(alice, 1_000_000e18);
        _fundStaking(1 ether);
        staking.notifyRewards();
        uint256 rate = staking.rewardRate();

        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        uint256 paidBefore = staking.claim();
        uint256 gasBefore = _lastGas();

        for (uint256 i; i < 1_000; ++i) {
            address u = _who(DUST_BASE, i);
            token.transfer(u, 1);
            _stakeAs(u, 1);
        }
        vm.warp(block.timestamp + 1 hours);
        vm.prank(alice);
        uint256 paidAfter = staking.claim();
        uint256 gasAfter = _lastGas();
        console2.log("alice's hourly claim gas: before / after 1,000 dust stakers", gasBefore, gasAfter);
        console2.log("alice's hourly claim (wei): before / after / rate x 3,600", paidBefore, paidAfter, rate * 3_600);
        assertApproxEqAbs(paidBefore, rate * 3_600, 1);
        assertApproxEqAbs(paidAfter, rate * 3_600, 1, "1,000 wei of dust stake takes nothing measurable");
        assertLe(gasAfter, gasBefore + gasBefore * FLAT_BPS / 10_000);
        for (uint256 i; i < 1_000; i += 100) {
            assertEq(staking.earned(_who(DUST_BASE, i)), 0, "1 wei of 1e24 earns under a wei");
        }
    }

    /// Dust sells: each swaps back only its own 1 wei; the next real sell swaps the rest as usual.
    function _dustSells() internal {
        _buy(bob, 0.05 ether); // 600,000 pending
        address duster = makeAddr("duster");
        token.transfer(duster, 200);
        vm.prank(duster);
        token.approve(address(router), 200);
        uint256 pending = token.balanceOf(address(token));
        assertGe(pending, token.swapThreshold());
        for (uint256 i; i < 200; ++i) {
            vm.prank(duster);
            router.swapExactTokensForETHSupportingFeeOnTransferTokens(
                1, 0, _path(address(token), address(weth)), duster, block.timestamp
            );
        }
        assertEq(token.balanceOf(address(token)), pending - 200, "200 dust sells took 200 wei of tax");
        uint256 reserveBefore = address(reserve).balance;
        _sell(bob, 1_000_000e18);
        assertEq(token.balanceOf(address(token)), 40_000e18, "the real sell swapped the rest");
        assertEq(address(reserve).balance - reserveBefore, (pending - 200) / router.TOKENS_PER_ETH() / 2);
    }

    /// Dust redemptions pay nothing, burn, and leave a real redeemer's payout as it was.
    function _dustRedemptions() internal {
        vm.deal(address(reserve), 10 ether);
        token.transfer(carol, 1_000_000e18);
        (uint256 previewBefore,,) = reserve.previewRedeem(1_000_000e18);
        uint256 held = address(reserve).balance;
        for (uint256 i; i < 1_000; ++i) {
            address u = _who(DUST_BASE, 1_000 + i);
            token.transfer(u, 1);
            _redeemAs(u, 1);
            assertEq(u.balance, 0);
        }
        assertEq(address(reserve).balance, held, "dust redemptions paid nothing");
        _redeemAs(carol, 1_000_000e18);
        assertGe(carol.balance, previewBefore, "the dust burns only raised backing");
        assertLe(carol.balance - previewBefore, 1, "by under a wei");
    }

    // ================================================================ 10. notify races

    /// notifyRewards in a crowded block: the second caller reverts TooSoon and changes nothing;
    /// tax ETH arriving after the call in the same block waits for the next funding, whole; stakes,
    /// claims and unstakes in the funding block earn nothing yet; many claims in one block later
    /// each get their exact share.
    function test_notify_race_and_same_block_arrivals() public {
        _launch();
        token.removeMaxWallet();
        token.transfer(alice, 1_000_000e18);
        token.transfer(bob, 1_000_000e18);
        token.transfer(carol, 1_000_000e18);
        _stakeAs(alice, 1_000_000e18);
        _stakeAs(bob, 1_000_000e18);
        _fundStaking(1 ether);
        staking.notifyRewards();
        uint256 rate = staking.rewardRate();
        uint256 finish = staking.periodFinish();

        vm.prank(carol);
        vm.expectRevert(Staking.TooSoon.selector);
        staking.notifyRewards();
        assertEq(staking.rewardRate(), rate);
        assertEq(staking.periodFinish(), finish);

        _fundStaking(0.5 ether); // a swap-back's share, later in the block
        assertEq(staking.rewardRate(), rate, "a late arrival does not change today's stream");

        _stakeAs(carol, 1_000_000e18);
        vm.prank(alice);
        vm.expectRevert(Staking.NothingToClaim.selector);
        staking.claim();
        vm.prank(carol);
        staking.withdraw(1_000_000e18);
        assertEq(staking.earned(carol), 0);

        vm.warp(block.timestamp + 1 days);
        vm.prank(alice);
        uint256 a = staking.claim();
        vm.prank(bob);
        uint256 b = staking.claim();
        assertApproxEqAbs(a, rate * 1 days / 2, 1);
        assertApproxEqAbs(b, rate * 1 days / 2, 1);

        uint256 owed = staking.totalAllocated() - staking.totalPaid();
        staking.notifyRewards();
        uint256 pool = address(staking).balance - owed;
        assertEq(staking.lastFundingAmount(), pool / 1 days * 1 days);
        assertGe(pool, 0.5 ether, "the late 0.5 ETH is in the next funding, whole");
        assertEq(address(staking).balance, stakingReceived - staking.totalPaid());
    }

    // ================================================================ 11. totalFunded counts each wei once

    /// ETH that streams while nothing is staked rolls into the next funding (SPEC 3.3) and streams
    /// again, but totalFunded counts it once: it is the ETH put into reward streams, each wei
    /// counted once, never more than Staking received. Here nobody stakes on day 1, so the whole
    /// day rolls over and day 2 streams the same ETH again: totalFunded stays at one day's stream
    /// (under the old count it doubled), while the stream itself is unchanged.
    function test_totalFunded_counts_rolled_over_eth_once() public {
        _launch();
        token.removeMaxWallet();
        _fundStaking(1 ether);
        staking.notifyRewards(); // nobody stakes today: the whole day rolls over
        uint256 streamedOnce = uint256(1 ether) / 1 days * 1 days;
        assertEq(staking.totalFunded(), streamedOnce);
        vm.warp(block.timestamp + 1 days);
        staking.notifyRewards(); // the same ETH is scheduled again
        assertEq(staking.lastFundingAmount(), streamedOnce, "the rolled-over day streams again, whole");
        assertEq(staking.totalFunded(), streamedOnce, "and is not counted again");
        assertLe(staking.totalFunded(), stakingReceived, "never more than the ETH received");
        assertEq(staking.totalAllocated(), 0);
    }

    // ================================================================ 11b. claims after an issuer burn

    /// While a stock token is paused, every redemption records its share as a claim (SPEC 3.2). If
    /// the issuer then burns part of the Reserve's balance of that token (adminBurn on any holder,
    /// SPEC 3.2a) so that it falls below totalClaims, every claimant bears the same haircut: a claim
    /// pays amount x balance / totalClaims, rounded down, and clears the whole record. Here 50
    /// claimants of different sizes, half of what the claims need burned, collecting in a
    /// scrambled order: all 50 are paid, each half its claim (rounded down, plus at most a wei for
    /// each claim collected before it, the rounding those left behind), and together they take the
    /// whole remaining balance.
    function test_claims_share_a_shortfall_pro_rata_after_an_issuer_burn() public {
        _launch();
        token.removeMaxWallet();
        vm.deal(address(reserve), 10 ether);
        amd.mint(address(reserve), 1_000e18);
        amd.setPaused(true);
        for (uint256 i; i < 50; ++i) {
            address u = _who(REDEEMER_BASE, i);
            uint256 amount = 1_000_000e18 + i * 10_007e18;
            token.transfer(u, amount);
            _redeemAs(u, amount);
        }
        uint256 owed = reserve.totalClaims(address(amd));
        assertGt(owed, 0);
        // The issuer burns the Reserve's AMD down to half of what the claims need.
        amd.adminBurn(address(reserve), amd.balanceOf(address(reserve)) - owed / 2);
        amd.setPaused(false);
        uint256 left = amd.balanceOf(address(reserve));
        assertLt(left, owed);

        uint256 paidTotal;
        uint256 maxOver;
        for (uint256 k; k < 50; ++k) {
            address u = _who(REDEEMER_BASE, (k * 17) % 50); // 17 is prime to 50: every claimant once
            uint256 claimed = reserve.claims(address(amd), u);
            assertGt(claimed, 0);
            vm.prank(u);
            reserve.claim(address(amd));
            uint256 got = amd.balanceOf(u);
            uint256 fair = Math.mulDiv(claimed, left, owed);
            assertGe(got, fair, "no claimant gets less than the shared fraction");
            assertLe(got, fair + k, "nor more than the rounding of the claims before it");
            assertEq(reserve.claims(address(amd), u), 0, "the whole record clears");
            if (got - fair > maxOver) maxOver = got - fair;
            paidTotal += got;
        }
        console2.log("50 claimants after the burn: owed / left / paid", owed, left, paidTotal);
        console2.log("largest excess over the shared fraction (wei)", maxOver);
        assertEq(reserve.totalClaims(address(amd)), 0, "every record cleared");
        assertEq(paidTotal, left, "the claims take the whole remaining balance");
        assertEq(amd.balanceOf(address(reserve)), 0);
    }

    // ================================================================ 12. block gas limit

    /// The one loop users can drive is redemption's pass over the listed assets, capped at
    /// MAX_ASSETS = 16, each read and transfer gas-capped (100,000 and 200,000). With all 13
    /// assets beyond the first three hostile (a transfer that burns every unit of gas it gets, or a
    /// balanceOf that does), a redemption stays far under a 32,000,000 block, and so do the views.
    /// forge-config: default.isolate = true
    function test_worst_case_redemption_with_16_assets_fits_a_block() public {
        HostileToken[] memory hostile = new HostileToken[](13);
        for (uint256 i; i < 13; ++i) {
            hostile[i] = new HostileToken();
            hostile[i].mint(address(reserve), 100e18);
            _listNow(address(hostile[i]), address(new MockFeed(8, 100e8)), 2);
        }
        assertEq(reserve.assetCount(), reserve.MAX_ASSETS());
        token.transfer(alice, 10_000_000e18);
        _launch();
        vm.deal(address(reserve), 10 ether);
        nvda.mint(address(reserve), 1_000e18);
        amd.mint(address(reserve), 1_000e18);
        mu.mint(address(reserve), 1_000e18);

        for (uint256 i; i < 13; ++i) {
            hostile[i].setTransferMode(HostileToken.Mode.BurnGas);
        }
        _redeemAs(alice, 1_000_000e18);
        uint256 burnTransfers = _lastGas();

        for (uint256 i; i < 13; ++i) {
            hostile[i].setTransferMode(HostileToken.Mode.Normal);
            hostile[i].setBalanceMode(HostileToken.Mode.BurnGas);
        }
        _redeemAs(alice, 1_000_000e18);
        uint256 burnBalances = _lastGas();
        reserve.previewRedeem(1_000_000e18);
        uint256 preview = _lastGas();
        reserve.reserveValue();
        uint256 value = _lastGas();

        console2.log(
            "16 assets, 13 hostile: redeem (transfers burn gas) / redeem (balanceOf burns gas)",
            burnTransfers,
            burnBalances
        );
        console2.log("16 assets, 13 hostile: previewRedeem / reserveValue", preview, value);
        uint256 bound = 16 * (reserve.BALANCE_GAS() + reserve.TRANSFER_GAS()) + 1_000_000;
        assertLt(burnTransfers, bound);
        assertLt(burnBalances, bound);
        assertLt(bound, BLOCK_GAS_LIMIT / 5, "the analytic bound is under a fifth of a block");
        assertLt(preview, BLOCK_GAS_LIMIT);
        assertLt(value, BLOCK_GAS_LIMIT);
    }

    // ================================================================ 13. registry and gateway

    /// Five years of monthly rotations and 500 Gateway settlements: publish, hasExecuted and settle
    /// cost the same at the end as at the start; the Gateway's lifetime totals match the supply
    /// burned and the ETH the host received.
    /// forge-config: default.isolate = true
    function test_registry_five_years_and_500_settlements_stay_flat() public {
        _launch();
        token.removeMaxWallet();
        GasStats memory publish;
        GasStats memory hasExecuted;
        uint16[5] memory weights = [uint16(4_000), 2_000, 2_000, 1_000, 1_000];
        for (uint256 i; i < 60; ++i) {
            registry.publish(weights, keccak256(abi.encode(i)), "ipfs://memo", uint64(block.timestamp + 30 days));
            _record(publish, _lastGas());
            vm.warp(block.timestamp + 30 days);
            assertTrue(registry.hasExecuted());
            _record(hasExecuted, _lastGas());
        }
        assertEq(registry.rotationCount(), 60);
        _assertFlat("WeightRegistry.publish", publish);
        _assertFlat("WeightRegistry.hasExecuted", hasExecuted);

        token.transfer(address(gateway), 50_000_000e18);
        uint256 supply0 = token.totalSupply();
        uint256 host0 = host.balance;
        GasStats memory settle;
        for (uint256 i; i < 500; ++i) {
            vm.prank(operator);
            gateway.settle(20_000e18, 2_000e18, 0);
            _record(settle, _lastGas());
        }
        assertEq(gateway.totalBurned(), 500 * 2_000e18);
        assertEq(gateway.totalSold(), 500 * 20_000e18);
        assertEq(supply0 - token.totalSupply(), gateway.totalBurned(), "supply fell only by the burns");
        assertEq(host.balance - host0, gateway.totalToHost());
        assertEq(token.balanceOf(address(gateway)), 50_000_000e18 - 500 * 22_000e18);
        _assertFlat("GatewaySettlement.settle", settle);
    }
}
