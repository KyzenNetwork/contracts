// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Script.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {Reserve} from "../../src/Reserve.sol";
import {Staking} from "../../src/Staking.sol";
import {PriceLib} from "../../src/lib/PriceLib.sol";
import {TestnetFeed} from "./TestnetFeed.sol";
import {TestnetScript, ITestnetUniswapV2Router, ITestnetUniswapV2Pair} from "./TestnetScript.sol";

/// Exercises a testnet deployment (deployments/<chainId>.json, written by DeployTestnet) end to
/// end. Staking streams rewards per second, and a forge script run simulates all of its calls at
/// one timestamp, so the user steps run in three invocations with time passing in between (on
/// anvil, `cast rpc evm_increaseTime` and `evm_mine`; on testnet, a few minutes):
///
///   run()        from the user's key: buys $KYZN until the buy's tax alone reaches the swap
///                threshold, then sells that much so the sell triggers the tax swap-back, and
///                checks the swap against the pool math and its split; then
///                notifyRewards() (when due) and stakes half of the wallet
///   claimEth()   from the user's key, later: claims the rewards in ETH
///   compound()   from the user's key, later again: sets Compound, claims as Compound with the
///                router's quote as the minimum (the buy is tax-free, so it must receive exactly
///                the quote), then redeems half of the wallet and checks what arrived against
///                previewRedeem
///   keeperBuy()  from the keeper's key (on testnet also the feeds' owner), once Router02's
///                24-hour target delay has passed and inside the purchase window: re-stamps the
///                three feeds and buys NVDA for the Reserve through Router02 within the price
///                bound, with the whole Reserve ETH up to the 1 ETH slice, or KYZEN_KEEPER_BUY_ETH wei
///   status()     prints balances, no transactions
///
/// Every step reverts in the simulation, before anything is sent, when a check fails.
contract Exercise is TestnetScript {
    using SafeERC20 for IERC20;

    error MaxWalletActive(uint256 wouldHold, uint256 maxWallet);
    error Mismatch(string what, uint256 expected, uint256 actual);
    error NothingEarnedYet();
    error NotKeeper(address keeper);
    error NotFeedOwner(address feed, address owner);
    error OutsideWindow(uint256 timestamp);
    error TargetNotLive(address target);
    error QuoteBelowBound(uint256 quote, uint256 bound);

    // ---------------------------------------------------------------- run: trade, fund, stake

    function run() external {
        Addresses memory a = _load();
        KyznToken token = KyznToken(payable(a.token));
        address user = msg.sender;

        _buy(a, token, user);
        _sellThroughSwapBack(a, token, user);

        Staking staking = Staking(payable(a.staking));
        if (block.timestamp >= staking.nextFundingAt()) {
            vm.startBroadcast(user);
            staking.notifyRewards();
            vm.stopBroadcast();
            console2.log("notifyRewards: funded (ETH)     ", _units(staking.lastFundingAmount()));
            console2.log("  streams until                 ", staking.periodFinish());
        } else {
            console2.log("notifyRewards: not due until    ", staking.nextFundingAt());
        }

        uint256 stakeAmount = token.balanceOf(user) / 2;
        uint256 stakedBefore = staking.stakedOf(user);
        vm.startBroadcast(user);
        IERC20(a.token).forceApprove(a.staking, stakeAmount);
        staking.stake(stakeAmount);
        vm.stopBroadcast();
        _same("staked", stakedBefore + stakeAmount, staking.stakedOf(user));
        console2.log("Staked ($KYZN)                  ", _units(stakeAmount));

        _status(a, user);
    }

    /// Buys enough that the buy's tax alone reaches the swap threshold, and checks the tax.
    function _buy(Addresses memory a, KyznToken token, address user) private {
        uint256 held = token.balanceOf(user);
        uint256 pendingBefore = token.balanceOf(a.token);
        (uint256 ethIn, uint256 net) = _buyOrder(a, token, held);

        vm.startBroadcast(user);
        ITestnetUniswapV2Router(a.router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: ethIn}(
            net, _path(WETH, a.token), user, block.timestamp + DEADLINE_WINDOW
        );
        vm.stopBroadcast();

        uint256 received = token.balanceOf(user) - held;
        uint256 tax = token.balanceOf(a.token) - pendingBefore;
        _same("buy tax (buyTaxBps of the gross)", (received + tax) * token.buyTaxBps() / token.BPS(), tax);
        console2.log("Buy: ETH in                     ", _units(ethIn));
        console2.log("  $KYZN out of the pool         ", _units(received + tax));
        console2.log("  $KYZN received                ", _units(received));
        console2.log("  $KYZN tax                     ", _units(tax));
    }

    /// The ETH that buys `gross` $KYZN out of the pool, where gross x buyTaxBps is the swap threshold,
    /// and the $KYZN the buyer receives net of the tax. Reverts while the max wallet would stop it.
    function _buyOrder(Addresses memory a, KyznToken token, uint256 held)
        private
        view
        returns (uint256 ethIn, uint256 net)
    {
        uint256 gross = Math.ceilDiv(token.swapThreshold() * token.BPS(), token.buyTaxBps());
        net = gross - gross * token.buyTaxBps() / token.BPS();
        if (token.maxWalletActive() && held + net > token.MAX_WALLET()) {
            revert MaxWalletActive(held + net, token.MAX_WALLET());
        }
        ethIn = ITestnetUniswapV2Router(a.router).getAmountsIn(gross, _path(WETH, a.token))[0];
    }

    /// A sell that triggers the tax swap-back, as the pool math predicts it.
    struct SellPlan {
        /// The tax held by the token before the sell (at least the swap threshold).
        uint256 pending;
        /// Of `pending`, the $KYZN recorded for the Reserve and for Staking.
        uint256 reserveTokens;
        uint256 stakingTokens;
        /// What the swap-back sells, and also what the seller sells: the whole pending tax.
        uint256 amount;
        /// The sell's own tax, left in the token after the swap-back.
        uint256 sellTax;
        /// ETH the swap-back receives: it runs first, inside the sell's transfer.
        uint256 swapEth;
        /// ETH the seller receives for the amount net of tax, after the swap-back moved the pool.
        uint256 sellerEth;
    }

    /// The token's TaxSwapped and TaxDistributed events.
    struct TaxSwap {
        uint256 sold;
        uint256 ethReceived;
        uint256 toReserve;
        uint256 toStaking;
        uint256 toDev;
    }

    /// Sells exactly what the swap-back will sell (the pending tax, at most 0.25% of the pool's
    /// $KYZN), so the sell triggers the tax swap-back on that whole amount; checks the ETH the
    /// swap-back received against the pool math, its split against the balances (2% Reserve,
    /// 1% Staking, the rest development), and the sell's own tax.
    function _sellThroughSwapBack(Addresses memory a, KyznToken token, address user) private {
        SellPlan memory s = _sellPlan(a, token);
        // Reserve ETH, Staking ETH, ETH held for the development wallet, all ETH held in the token.
        uint256[4] memory before =
            [a.reserve.balance, a.staking.balance, token.heldEth(a.devWallet), token.totalHeldEth()];

        vm.recordLogs();
        vm.startBroadcast(user);
        IERC20(a.token).forceApprove(a.router, s.amount);
        ITestnetUniswapV2Router(a.router)
            .swapExactTokensForETHSupportingFeeOnTransferTokens(
                s.amount, s.sellerEth, _path(a.token, WETH), user, block.timestamp + DEADLINE_WINDOW
            );
        vm.stopBroadcast();
        TaxSwap memory t = _taxEvents(a.token);

        _same("tax swapped", s.amount, t.sold);
        _same("swap-back ETH (pool math)", s.swapEth, t.ethReceived);
        // The sold $KYZN carries the Reserve's and Staking's recorded shares in proportion (2 and
        // 1 points of each trade at its own tax level); development the rest.
        uint256 reserveSold = s.reserveTokens * s.amount / s.pending;
        uint256 stakingSold = s.stakingTokens * s.amount / s.pending;
        _same("Reserve share (its recorded tax)", t.ethReceived * reserveSold / s.amount, t.toReserve);
        _same("Staking share (its recorded tax)", t.ethReceived * stakingSold / s.amount, t.toStaking);
        _same("Reserve tax still recorded", s.reserveTokens - reserveSold + s.sellTax * token.RESERVE_BPS() / token.sellTaxBps(), token.reserveTaxTokens());
        _same("development share (the rest, with dust)", t.ethReceived - t.toReserve - t.toStaking, t.toDev);
        _same("Reserve ETH", before[0] + t.toReserve, a.reserve.balance);
        _same("Staking ETH", before[1] + t.toStaking, a.staking.balance);
        _same("development share held to claim", before[2] + t.toDev, token.heldEth(a.devWallet));
        _same("ETH held in the token", before[3] + t.toDev, token.totalHeldEth());
        _same("pending tax after the sell", s.pending - s.amount + s.sellTax, token.balanceOf(a.token));

        console2.log("Sell: $KYZN sold                ", _units(s.amount));
        console2.log("  seller ETH (pool math)        ", _units(s.sellerEth));
        console2.log("  sell tax ($KYZN)              ", _units(s.sellTax));
        console2.log("Swap-back: $KYZN sold           ", _units(t.sold));
        console2.log("  ETH received                  ", _units(t.ethReceived));
        console2.log("  to Reserve                    ", _units(t.toReserve));
        console2.log("  to Staking                    ", _units(t.toStaking));
        console2.log("  to development                ", _units(t.toDev));
    }

    function _sellPlan(Addresses memory a, KyznToken token) private view returns (SellPlan memory s) {
        s.pending = token.balanceOf(a.token);
        if (s.pending < token.swapThreshold()) {
            revert Mismatch("pending tax at the threshold", token.swapThreshold(), s.pending);
        }
        s.reserveTokens = token.reserveTaxTokens();
        s.stakingTokens = token.stakingTaxTokens();
        s.amount = Math.min(s.pending, IERC20(a.token).balanceOf(a.pair) * token.SWAP_POOL_BPS() / token.BPS());
        s.sellTax = s.amount * token.sellTaxBps() / token.BPS();
        (uint256 kyznReserve, uint256 wethReserve) = _reserves(a.pair, a.token);
        s.swapEth = _amountOut(s.amount, kyznReserve, wethReserve);
        s.sellerEth = _amountOut(s.amount - s.sellTax, kyznReserve + s.amount, wethReserve - s.swapEth);
    }

    // ---------------------------------------------------------------- claimEth

    function claimEth() external {
        Addresses memory a = _load();
        Staking staking = Staking(payable(a.staking));
        address user = msg.sender;
        uint256 earned = staking.earned(user);
        if (earned == 0) revert NothingEarnedYet();

        vm.startBroadcast(user);
        uint256 paid = staking.claim();
        vm.stopBroadcast();

        _same("ETH claimed", earned, paid);
        console2.log("Claim ETH: paid (ETH)           ", _units(paid));
        _status(a, user);
    }

    // ---------------------------------------------------------------- compound, then redeem

    function compound() external {
        Addresses memory a = _load();
        Staking staking = Staking(payable(a.staking));
        address user = msg.sender;
        uint256 earned = staking.earned(user);
        if (earned == 0) revert NothingEarnedYet();

        uint256 quote = ITestnetUniswapV2Router(a.router).getAmountsOut(earned, _path(WETH, a.token))[1];
        uint256 stakedBefore = staking.stakedOf(user);
        vm.startBroadcast(user);
        staking.setPayoutMode(Staking.PayoutMode.Compound);
        // 1% below the quote, so a pool move between simulation and broadcast does not revert
        // the claim; the simulated fill is still checked against the exact untaxed quote below.
        uint256 added = staking.claimCompound(quote * 99 / 100);
        vm.stopBroadcast();

        _same("Compound $KYZN (the untaxed quote)", quote, added);
        _same("stake after Compound", stakedBefore + added, staking.stakedOf(user));
        console2.log("Compound: ETH claimed           ", _units(earned));
        console2.log("  $KYZN added to the stake      ", _units(added));

        _redeem(a, user, IERC20(a.token).balanceOf(user) / 2);
        _status(a, user);
    }

    /// Redeems `amount` and checks every payout against previewRedeem.
    function _redeem(Addresses memory a, address user, uint256 amount) private {
        Reserve reserve = Reserve(payable(a.reserve));
        (uint256 ethOut, address[] memory tokens, uint256[] memory amounts) = reserve.previewRedeem(amount);
        uint256[] memory before = new uint256[](tokens.length);
        for (uint256 i; i < tokens.length; ++i) {
            before[i] = IERC20(tokens[i]).balanceOf(user);
        }
        uint256 ethBefore = user.balance;
        uint256 supplyBefore = IERC20(a.token).totalSupply();

        vm.startBroadcast(user);
        IERC20(a.token).forceApprove(a.reserve, amount);
        reserve.redeem(amount);
        vm.stopBroadcast();

        _same("$KYZN burned", supplyBefore - amount, IERC20(a.token).totalSupply());
        _same("redemption ETH", ethOut, user.balance - ethBefore);
        console2.log("Redeem: $KYZN burned            ", _units(amount));
        console2.log("  ETH paid                      ", _units(ethOut));
        for (uint256 i; i < tokens.length; ++i) {
            _same("redemption in kind", amounts[i], IERC20(tokens[i]).balanceOf(user) - before[i]);
            console2.log(string.concat("  ", IERC20Metadata(tokens[i]).symbol(), " paid"), _units(amounts[i]));
        }
    }

    // ---------------------------------------------------------------- keeperBuy

    /// A keeper purchase of NVDA through Router02, sized and priced before it is sent.
    struct Order {
        uint256 ethIn;
        /// NVDA the Chainlink prices imply for ethIn.
        uint256 implied;
        /// The Reserve's price bound: 98.5% of implied.
        uint256 bound;
        /// Router02's quote, also the keeper's minimum.
        uint256 quote;
        bytes data;
    }

    function keeperBuy() external {
        Addresses memory a = _load();
        address keeper = msg.sender;
        TestnetFeed[3] memory feeds = [TestnetFeed(a.nvdaFeed), TestnetFeed(a.amdFeed), TestnetFeed(a.ethUsdFeed)];
        _checkKeeper(a, keeper, feeds);

        // Re-stamp: the same answers, updated now (the pools were seeded at these prices).
        vm.startBroadcast(keeper);
        for (uint256 i; i < feeds.length; ++i) {
            feeds[i].set(feeds[i].answer(), block.timestamp);
        }
        vm.stopBroadcast();

        Order memory o = _order(a);
        uint256 nvdaBefore = IERC20(a.nvda).balanceOf(a.reserve);
        vm.startBroadcast(keeper);
        uint256 received = Reserve(payable(a.reserve)).buy(a.nvda, a.router, o.data, o.ethIn, o.quote);
        vm.stopBroadcast();

        _same("NVDA received (the quote)", o.quote, received);
        _same("Reserve NVDA", nvdaBefore + received, IERC20(a.nvda).balanceOf(a.reserve));
        console2.log("Keeper buy: ETH spent           ", _units(o.ethIn));
        console2.log("  NVDA the feeds imply          ", _units(o.implied));
        console2.log("  NVDA bound (98.5%)            ", _units(o.bound));
        console2.log("  NVDA received                 ", _units(received));
        console2.log("  received / implied (bps)      ", received * 10_000 / o.implied);
        _status(a, keeper);
    }

    function _checkKeeper(Addresses memory a, address keeper, TestnetFeed[3] memory feeds) private view {
        Reserve reserve = Reserve(payable(a.reserve));
        if (reserve.keeper() != keeper) revert NotKeeper(reserve.keeper());
        if (!PriceLib.inPurchaseWindow(block.timestamp)) revert OutsideWindow(block.timestamp);
        if (!reserve.isTargetAllowed(a.router)) revert TargetNotLive(a.router);
        for (uint256 i; i < feeds.length; ++i) {
            if (feeds[i].owner() != keeper) revert NotFeedOwner(address(feeds[i]), feeds[i].owner());
        }
    }

    /// The whole Reserve ETH up to the 1 ETH slice (or KYZEN_KEEPER_BUY_ETH wei), with Router02's
    /// quote as the minimum; reverts when the quote misses the price bound (a pool too shallow for
    /// the slice), since the Reserve would reject the purchase.
    function _order(Addresses memory a) private view returns (Order memory o) {
        Reserve reserve = Reserve(payable(a.reserve));
        o.ethIn = vm.envOr("KYZEN_KEEPER_BUY_ETH", Math.min(a.reserve.balance, reserve.MAX_SLICE()));
        o.implied = Math.mulDiv(o.ethIn, _answer(a.ethUsdFeed), _answer(a.nvdaFeed));
        o.bound = o.implied * reserve.PRICE_BOUND_BPS() / reserve.BPS();
        address[] memory path = _path(WETH, a.nvda);
        o.quote = ITestnetUniswapV2Router(a.router).getAmountsOut(o.ethIn, path)[1];
        if (o.quote < o.bound) revert QuoteBelowBound(o.quote, o.bound);
        o.data = abi.encodeCall(
            ITestnetUniswapV2Router.swapExactTokensForTokens,
            (o.ethIn, o.quote, path, a.reserve, block.timestamp + DEADLINE_WINDOW)
        );
    }

    // ---------------------------------------------------------------- status

    function status() external view {
        _status(_load(), msg.sender);
    }

    function _status(Addresses memory a, address user) private view {
        KyznToken token = KyznToken(payable(a.token));
        Reserve reserve = Reserve(payable(a.reserve));
        Staking staking = Staking(payable(a.staking));
        (uint256 kyznReserve, uint256 wethReserve) = _reserves(a.pair, a.token);
        (uint256 backing,) = reserve.backingPerToken();
        (uint256 value, uint256 oldest) = reserve.reserveValue();

        console2.log("---- status at", block.timestamp);
        console2.log("$KYZN total supply              ", _units(token.totalSupply()));
        console2.log("Pool $KYZN / WETH               ", _units(kyznReserve), _units(wethReserve));
        console2.log("Pending tax ($KYZN)             ", _units(token.balanceOf(a.token)));
        console2.log("User                            ", user);
        console2.log("  ETH                           ", _units(user.balance));
        console2.log("  $KYZN wallet                  ", _units(token.balanceOf(user)));
        console2.log("  $KYZN staked                  ", _units(staking.stakedOf(user)));
        console2.log("  earned (ETH)                  ", _units(staking.earned(user)));
        console2.log(
            "  NVDA / AMD                    ",
            _units(IERC20(a.nvda).balanceOf(user)),
            _units(IERC20(a.amd).balanceOf(user))
        );
        console2.log("Reserve ETH                     ", _units(a.reserve.balance));
        console2.log(
            "  NVDA / AMD                    ",
            _units(IERC20(a.nvda).balanceOf(a.reserve)),
            _units(IERC20(a.amd).balanceOf(a.reserve))
        );
        console2.log("  value (USD) / backing per $KYZN (USD)", _units(value), _units(backing));
        console2.log("  oldest price update           ", oldest);
        console2.log("  Router02 target live          ", reserve.isTargetAllowed(a.router));
        console2.log("Staking ETH                     ", _units(a.staking.balance));
        console2.log("  total staked ($KYZN)          ", _units(staking.totalStaked()));
        console2.log("  total funded / paid (ETH)     ", _units(staking.totalFunded()), _units(staking.totalPaid()));
        console2.log("Development ETH to claim        ", _units(KyznToken(payable(a.token)).heldEth(a.devWallet)));
    }

    // ---------------------------------------------------------------- helpers

    function _answer(address feed) private view returns (uint256) {
        (, int256 answer,,,) = TestnetFeed(feed).latestRoundData();
        if (answer <= 0) revert Mismatch("positive feed answer", 1, 0);
        // Checked positive above, so the cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer);
    }

    function _reserves(address pair, address token) private view returns (uint256 tokenReserve, uint256 wethReserve) {
        (uint112 r0, uint112 r1,) = ITestnetUniswapV2Pair(pair).getReserves();
        (tokenReserve, wethReserve) =
            ITestnetUniswapV2Pair(pair).token0() == token ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
    }

    /// UniswapV2Library.getAmountOut: the 0.3% fee, then the constant product.
    function _amountOut(uint256 amountIn, uint256 reserveIn, uint256 reserveOut) private pure returns (uint256) {
        uint256 withFee = amountIn * 997;
        return withFee * reserveOut / (reserveIn * 1000 + withFee);
    }

    /// The token's TaxSwapped and TaxDistributed events from the recorded logs; each exactly once.
    function _taxEvents(address token) private view returns (TaxSwap memory t) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swapped;
        uint256 distributed;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != token) continue;
            if (logs[i].topics[0] == KyznToken.TaxSwapped.selector) {
                (t.sold, t.ethReceived) = abi.decode(logs[i].data, (uint256, uint256));
                ++swapped;
            } else if (logs[i].topics[0] == KyznToken.TaxDistributed.selector) {
                (t.toReserve, t.toStaking, t.toDev) = abi.decode(logs[i].data, (uint256, uint256, uint256));
                ++distributed;
            }
        }
        _same("TaxSwapped events", 1, swapped);
        _same("TaxDistributed events", 1, distributed);
    }

    function _same(string memory what, uint256 expected, uint256 actual) private pure {
        if (expected != actual) revert Mismatch(what, expected, actual);
    }
}
