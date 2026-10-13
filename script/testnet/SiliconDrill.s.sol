// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznUsdOracle} from "../../src/silicon/KyznUsdOracle.sol";
import {MarketCalendar} from "../../src/silicon/MarketCalendar.sol";
import {SiliconSynth} from "../../src/silicon/SiliconSynth.sol";
import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {StockIndexFeed} from "../../src/silicon/StockIndexFeed.sol";
import {TestnetFeed} from "./TestnetFeed.sol";
import {TestnetUsdg} from "./TestnetUsdg.sol";
import {TestnetScript, ITestnetUniswapV2Router, ITestnetUniswapV2Pair} from "./TestnetScript.sol";

/// The live Silicon drills on Robinhood Chain testnet (46630), or on an anvil fork of it (31337)
/// for a rehearsal, against the deployment under "silicon" in deployments/46630.json (read on
/// both chains). The deployer is the only actor: it owns the stand-in feeds, the USDG stand-in and
/// the vault, and is the index feeds' guardian. Its key is given with --private-key; every step
/// that sends checks that the sender is the deployer recorded in the file (status() needs no key).
///
/// Steps, each its own invocation (--sig), each printing what it did and the values a
/// transaction changed. Only prepare, buy, push, clear, repayPart and restore send anything
/// outside the minting window (Monday to Friday 14:30 to 20:00 UTC, not a holiday); positions,
/// withdrawPart, liquidate and mint refuse outside it.
///   prepare()          stamps ETH/USD and the seven stock stand-ins again at their answers,
///                      dated now; syncs the four index feeds; tops the deployer's test USDG up to
///                      USDG_FLOAT; sets each market's minimum debt to DRILL_MIN_DEBT (testnet only,
///                      so the drill fits the shallow testnet pool; the old values are printed and
///                      restore() puts back those in the deployment file); records an oracle
///                      observation if one is due. Idempotent apart from the new stamps.
///   buy(uint256 wei)   buys $KYZN for the deployer through Router02 with `wei` of ETH (the
///                      deployer holds none). Run it at least 40 minutes before positions(), so
///                      the oracle's 30-minute long average holds only the price after the buy.
///   positions()        needs the window and an oracle price. On kMEMORY: deposits $KYZN
///                      (MEMORY_KYZN_BPS of the deployer's) and USDG for a 60% $KYZN position,
///                      mints at about 160%, repays a quarter of the debt, withdraws a fifth of the
///                      collateral. On kFAB: deposits FAB_KYZN_BPS of the $KYZN and USDG, mints at
///                      about 151%. A market where the deployer already owes something is skipped,
///                      so a rerun after a failure finishes the other market; deposits already made
///                      count toward the next mint.
///   repayPart()        the kMEMORY repay alone (a quarter of the debt), and
///   withdrawPart()     the kMEMORY withdrawal alone (a fifth of the collateral; needs the window):
///                      to finish positions() when it stopped after the kMEMORY mint. In that order.
///   push(string, int, bool)
///                      sets a stock stand-in to its answer x (10,000 + bps) / 10,000, dated now,
///                      and syncs the index feeds. A move of more than 30% of the answer is a jump
///                      (the feed's own test): the breaker latches until clear(). The flag says
///                      which is meant: a jump without it, or no jump with it, is refused.
///   liquidate()        needs the window. Starts the auction of the deployer's kFAB position once
///                      it is below 150% (or takes the one already running), mints on kFAB what the
///                      deployer lacks to bid it out in full (a fresh kFAB position at about 160%:
///                      startAuction emptied the old one), then bids the debt and the penalty.
///   clear(string)      the guardian clears every index component on that stand-in that reads
///                      as stopped, at the stand-in's latest round.
///   mint(string, uint) mints `amount` of a synth ("kMEMORY", ...) on the deployer's position. The
///                      mint is first tried in the simulation: when the vault refuses it, the reason
///                      is printed and nothing is sent.
///   restore()          repays what the deployer's synth covers (in full, or down to the drill's
///                      minimum debt), withdraws the collateral of positions that owe nothing, then
///                      sets each market's minimum debt and debt ceiling back to the deployment
///                      file's values.
///   status()           prints prices, freshness and the deployer's positions; sends nothing.
///
/// Run from contracts/, for example:
///   forge script script/testnet/SiliconDrill.s.sol:SiliconDrill --sig "prepare()" \
///     --rpc-url robinhood_testnet --private-key "$(cat ~/.kyzen/testnet/deployer.key)" \
///     --broadcast --slow --gas-estimate-multiplier 200
/// The runbook, in order and with its timing, is in docs/superpowers/silicon-drills.md.
contract SiliconDrill is TestnetScript {
    using SafeERC20 for IERC20;

    /// The Silicon deployment, on testnet and on an anvil fork of it alike.
    string internal constant SILICON_DEPLOYMENT = "deployments/46630.json";
    uint256 internal constant STOCKS = 7;
    uint256 internal constant MARKETS = 4;
    uint256 internal constant MEMORY = 1;
    uint256 internal constant FAB = 2;
    uint256 internal constant BPS = 10_000;
    int256 internal constant BPS_SIGNED = 10_000;
    uint256 internal constant RATIO_BPS = 15_000;
    uint256 internal constant JUMP_BPS = 3_000;
    /// The drill's minimum debt per position, in synth (about $1): testnet only.
    uint256 internal constant DRILL_MIN_DEBT = 0.01e18;
    /// The test USDG prepare() keeps on the deployer.
    uint256 internal constant USDG_FLOAT = 1_000e6;
    /// $KYZN's share of each drill position's collateral value.
    uint256 internal constant KYZN_SHARE_BPS = 6_000;
    /// Of the deployer's $KYZN, what goes into kMEMORY and into kFAB; the rest is kept for the
    /// position that mints the bid's synth.
    uint256 internal constant MEMORY_KYZN_BPS = 3_500;
    uint256 internal constant FAB_KYZN_BPS = 3_500;
    /// The collateral ratios the positions open at.
    uint256 internal constant MEMORY_RATIO_BPS = 16_000;
    uint256 internal constant FAB_RATIO_BPS = 15_100;
    uint256 internal constant BIDDER_RATIO_BPS = 16_000;
    /// The part of the kMEMORY mint repaid, and of its collateral withdrawn.
    uint256 internal constant REPAY_BPS = 2_500;
    uint256 internal constant WITHDRAW_BPS = 2_000;
    /// buy() accepts at least this share of Router02's quote (the quote is before the $KYZN tax).
    uint256 internal constant BUY_MIN_OUT_BPS = 9_000;
    /// How many of the latest auctions liquidate() looks through for the deployer's.
    uint256 internal constant AUCTION_LOOKBACK = 32;

    /// The Silicon deployment as the deployment file records it.
    struct Silicon {
        address deployer;
        IERC20 kyzn;
        address pair;
        address router;
        TestnetFeed ethUsd;
        SiliconVault vault;
        KyznUsdOracle oracle;
        MarketCalendar calendar;
        TestnetUsdg usdg;
        TestnetFeed[STOCKS] stocks;
        string[STOCKS] tickers;
        StockIndexFeed[MARKETS] feeds;
        SiliconSynth[MARKETS] synths;
        string[MARKETS] symbols;
        uint256[MARKETS] minDebt;
        uint256[MARKETS] debtCeiling;
    }

    /// One position's opening: what goes in and what is minted.
    struct Opening {
        uint256 kyzn;
        uint256 usdg;
        uint256 mint;
    }

    error NotDeployer(address sender, address deployer);
    error OutsideWindow(uint256 timestamp);
    error NotFresh(address feed);
    error NoKyzn();
    error NotEnoughKyzn(uint256 held, uint256 needed);
    error MintTooSmall(uint256 id, uint256 amount, uint256 minimum);
    error KyznShareTooLow(uint256 id, uint256 shareBps);
    error UnknownTicker(string ticker);
    error UnknownSymbol(string symbol);
    error BadAnswer(int256 answer);
    error NothingToLiquidate();
    error StillHealthy(uint256 ratioBps);
    error DeploymentMismatch(string what);
    error JumpFlagMismatch(bool moveIsJump, bool jumpFlag);
    error NoDebt(uint256 id);

    // ================================================================ steps

    /// Stamps, syncs, USDG and the drill's minimum debt. Works at any hour.
    function prepare() external {
        Silicon memory s = _silicon();
        vm.startBroadcast(s.deployer);
        _stamp(s.ethUsd, "ETH/USD");
        for (uint256 i; i < STOCKS; ++i) {
            _stamp(s.stocks[i], s.tickers[i]);
        }
        for (uint256 id; id < MARKETS; ++id) {
            s.feeds[id].sync();
        }
        uint256 held = s.usdg.balanceOf(s.deployer);
        if (held < USDG_FLOAT) {
            s.usdg.mint(s.deployer, USDG_FLOAT - held);
            console2.log("USDG minted to the deployer   ", _units(_usd(s, USDG_FLOAT - held)));
        } else {
            console2.log("USDG held, none minted        ", _units(_usd(s, held)));
        }
        for (uint256 id; id < MARKETS; ++id) {
            uint256 current = s.vault.market(id).minDebt;
            console2.log(string.concat(s.symbols[id], " minDebt was "), _units(current));
            console2.log("  recorded in 46630.json      ", _units(s.minDebt[id]));
            if (current != DRILL_MIN_DEBT) {
                s.vault.setMinDebt(id, DRILL_MIN_DEBT);
                console2.log("  set to                      ", _units(DRILL_MIN_DEBT));
            }
        }
        if (s.oracle.due()) {
            s.oracle.update();
            console2.log("Oracle observation recorded at", block.timestamp);
        }
        vm.stopBroadcast();
        _status(s);
    }

    /// Buys $KYZN for the deployer with `weiIn` of ETH.
    function buy(uint256 weiIn) external {
        Silicon memory s = _silicon();
        address[] memory path = _path(WETH, address(s.kyzn));
        uint256 quote = ITestnetUniswapV2Router(s.router).getAmountsOut(weiIn, path)[1];
        uint256 before = s.kyzn.balanceOf(s.deployer);
        vm.startBroadcast(s.deployer);
        ITestnetUniswapV2Router(s.router).swapExactETHForTokensSupportingFeeOnTransferTokens{value: weiIn}(
            quote * BUY_MIN_OUT_BPS / BPS, path, s.deployer, block.timestamp + DEADLINE_WINDOW
        );
        vm.stopBroadcast();
        console2.log("ETH spent                     ", _units(weiIn));
        console2.log("$KYZN received                ", _units(s.kyzn.balanceOf(s.deployer) - before));
        console2.log("Pool spot, WETH per 1e18 $KYZN", _spot(s));
        _status(s);
    }

    /// The kMEMORY position (deposit, mint, repay part, withdraw part) and the kFAB position.
    function positions() external {
        Silicon memory s = _silicon();
        _requireWindow(s);
        uint256 kyznPrice = s.oracle.price(); // reverts while the oracle has no price
        _requireFresh(s, MEMORY);
        _requireFresh(s, FAB);
        uint256 held = s.kyzn.balanceOf(s.deployer);
        if (held == 0) revert NoKyzn();
        console2.log("$KYZN/USD (1e18)              ", kyznPrice);
        console2.log("$KYZN held                    ", _units(held));

        (,, uint256 memoryShares) = s.vault.positions(MEMORY, s.deployer);
        if (memoryShares == 0) _memoryPosition(s, held * MEMORY_KYZN_BPS / BPS, kyznPrice);
        else console2.log("kMEMORY: the deployer already owes; skipped");
        (,, uint256 fabShares) = s.vault.positions(FAB, s.deployer);
        if (fabShares == 0) _fabPosition(s, held * FAB_KYZN_BPS / BPS, kyznPrice);
        else console2.log("kFAB: the deployer already owes; skipped");
        _status(s);
    }

    /// Moves stock stand-in `ticker` by `bps` (negative for a fall), dated now; `jump` says
    /// whether the move is meant to trip the breaker.
    function push(string calldata ticker, int256 bps, bool jump) external {
        Silicon memory s = _silicon();
        TestnetFeed f = s.stocks[_ticker(s, ticker)];
        (, int256 answer,,,) = f.latestRoundData();
        int256 next = answer * (BPS_SIGNED + bps) / BPS_SIGNED;
        if (next <= 0) revert BadAnswer(next);
        // StockIndexFeed's own test for a jump between two rounds.
        bool isJump = _abs(next - answer) > Math.mulDiv(_abs(answer), JUMP_BPS, BPS);
        if (isJump != jump) revert JumpFlagMismatch(isJump, jump);
        vm.startBroadcast(s.deployer);
        f.set(next, block.timestamp);
        for (uint256 id; id < MARKETS; ++id) {
            s.feeds[id].sync();
        }
        vm.stopBroadcast();
        console2.log(string.concat(ticker, " answer was (1e8)"), answer);
        console2.log(string.concat(ticker, " answer now (1e8)"), next);
        console2.log("  round                       ", uint256(f.roundId()));
        console2.log("  moved (bps)                 ", bps);
        console2.log(isJump ? "  a jump: the breaker latches until clear()" : "  inside the breaker's 30%");
        _status(s);
    }

    /// Auctions the deployer's kFAB position once below 150% and bids it out in full.
    function liquidate() external {
        Silicon memory s = _silicon();
        _requireWindow(s);
        (uint256 aid, bool running) = _runningAuction(s, FAB);
        if (running) {
            console2.log("Auction already running       ", aid);
        } else {
            (,, uint256 shares) = s.vault.positions(FAB, s.deployer);
            if (shares == 0) revert NothingToLiquidate();
            (,, uint256 ratio,) = s.vault.health(FAB, s.deployer);
            if (ratio >= RATIO_BPS) revert StillHealthy(ratio);
            console2.log("kFAB ratio before (bps)       ", ratio);
            vm.startBroadcast(s.deployer);
            aid = s.vault.startAuction(s.deployer, FAB);
            vm.stopBroadcast();
            console2.log("Auction started               ", aid);
        }
        SiliconVault.Auction memory a = s.vault.auction(aid);
        uint256 owed = a.debt + a.penalty;
        uint256 pay = Math.min(owed, s.vault.auctionPrice(aid));
        console2.log("  debt (kFAB)                 ", _units(a.debt));
        console2.log("  penalty (kFAB)              ", _units(a.penalty));
        console2.log("  lot price now (kFAB)        ", _units(s.vault.auctionPrice(aid)));
        uint256 have = s.synths[FAB].balanceOf(s.deployer);
        if (have < pay) _mintForBid(s, pay - have);

        vm.startBroadcast(s.deployer);
        (uint256 paid, uint256 kyznOut, uint256 usdgOut) = s.vault.bid(aid, pay);
        vm.stopBroadcast();
        console2.log("Bid paid (kFAB)               ", _units(paid));
        console2.log("  $KYZN received              ", _units(kyznOut));
        console2.log("  USDG received               ", _units(_usd(s, usdgOut)));
        console2.log(s.vault.auction(aid).account == address(0) ? "  auction closed" : "  auction still running");
        SiliconVault.Market memory m = s.vault.market(FAB);
        console2.log("  kFAB bad debt               ", _units(m.badDebt));
        _status(s);
    }

    /// The guardian clears each stopped index component on stand-in `ticker` at its latest round.
    function clear(string calldata ticker) external {
        Silicon memory s = _silicon();
        TestnetFeed f = s.stocks[_ticker(s, ticker)];
        uint80 latest = f.roundId();
        vm.startBroadcast(s.deployer);
        for (uint256 id; id < MARKETS; ++id) {
            uint256 n = s.feeds[id].componentCount();
            for (uint256 j; j < n; ++j) {
                (address feed,,) = s.feeds[id].component(j);
                if (feed != address(f)) continue;
                if (s.feeds[id].jumped(j)) {
                    s.feeds[id].clearJump(j, latest);
                    console2.log(string.concat(s.symbols[id], ": cleared component"), j);
                    console2.log("  at round                    ", uint256(latest));
                } else {
                    console2.log(string.concat(s.symbols[id], ": component not stopped"), j);
                }
            }
        }
        vm.stopBroadcast();
        _status(s);
    }

    /// Mints `amount` of `symbol` on the deployer's position, if the vault accepts it now.
    function mint(string calldata symbol, uint256 amount) external {
        Silicon memory s = _silicon();
        uint256 id = _symbol(s, symbol);
        uint256 snapshot = vm.snapshotState();
        vm.prank(s.deployer);
        (bool ok, bytes memory reason) = address(s.vault).call(abi.encodeCall(SiliconVault.mint, (id, amount)));
        vm.revertToState(snapshot);
        if (!ok) {
            console2.log(string.concat(symbol, " mint refused; nothing sent"));
            _logRevert(reason);
            _status(s);
            return;
        }
        vm.startBroadcast(s.deployer);
        s.vault.mint(id, amount);
        vm.stopBroadcast();
        console2.log(string.concat(symbol, " minted"), _units(amount));
        _status(s);
    }

    /// Repays and withdraws what it can, then puts the deployment file's levels back.
    function restore() external {
        Silicon memory s = _silicon();
        vm.startBroadcast(s.deployer);
        for (uint256 id; id < MARKETS; ++id) {
            _restorePosition(s, id);
        }
        for (uint256 id; id < MARKETS; ++id) {
            SiliconVault.Market memory m = s.vault.market(id);
            if (m.minDebt != s.minDebt[id]) {
                s.vault.setMinDebt(id, s.minDebt[id]);
                console2.log(string.concat(s.symbols[id], " minDebt back to"), _units(s.minDebt[id]));
            }
            if (m.debtCeiling != s.debtCeiling[id]) {
                s.vault.setDebtCeiling(id, s.debtCeiling[id]);
                console2.log(string.concat(s.symbols[id], " debtCeiling back to"), _units(s.debtCeiling[id]));
            }
        }
        vm.stopBroadcast();
        _status(s);
    }

    /// Prints the state; sends nothing.
    function status() external view {
        _status(_load46630());
    }

    /// The kMEMORY repay of positions() alone: a quarter of the deployer's kMEMORY debt.
    function repayPart() external {
        Silicon memory s = _silicon();
        _repayPart(s);
        _status(s);
    }

    /// The kMEMORY withdrawal of positions() alone: a fifth of the position's collateral. Needs the
    /// window (a withdrawal with debt reads the prices).
    function withdrawPart() external {
        Silicon memory s = _silicon();
        _requireWindow(s);
        _withdrawPart(s);
        _status(s);
    }

    // ================================================================ positions

    /// kMEMORY: deposit and mint, then the repay and the withdrawal (each its own transaction;
    /// repayPart() and withdrawPart() finish a run that stopped after the mint).
    function _memoryPosition(Silicon memory s, uint256 kyznIn, uint256 kyznPrice) private {
        Opening memory o = _size(s, MEMORY, kyznIn, kyznPrice, MEMORY_RATIO_BPS);
        uint256 minimum = s.vault.market(MEMORY).minDebt;
        if (o.mint * (BPS - REPAY_BPS) / BPS < minimum) revert MintTooSmall(MEMORY, o.mint, minimum);
        vm.startBroadcast(s.deployer);
        _deposit(s, MEMORY, o);
        s.vault.mint(MEMORY, o.mint);
        vm.stopBroadcast();
        console2.log("kMEMORY deposited $KYZN       ", _units(o.kyzn));
        console2.log("  deposited USDG              ", _units(_usd(s, o.usdg)));
        console2.log("  minted                      ", _units(o.mint));
        _repayPart(s);
        _withdrawPart(s);
    }

    /// Repays REPAY_BPS of the deployer's kMEMORY debt. Reads no price.
    function _repayPart(Silicon memory s) private {
        uint256 debt = s.vault.debtOf(MEMORY, s.deployer);
        if (debt == 0) revert NoDebt(MEMORY);
        uint256 amount = debt * REPAY_BPS / BPS;
        uint256 minimum = s.vault.market(MEMORY).minDebt;
        if (debt - amount < minimum) revert MintTooSmall(MEMORY, debt, minimum);
        vm.startBroadcast(s.deployer);
        s.vault.repay(MEMORY, amount);
        vm.stopBroadcast();
        console2.log("kMEMORY repaid                ", _units(amount));
    }

    /// Withdraws WITHDRAW_BPS of each collateral of the deployer's kMEMORY position.
    function _withdrawPart(Silicon memory s) private {
        (uint256 k, uint256 u, uint256 shares) = s.vault.positions(MEMORY, s.deployer);
        if (shares == 0) revert NoDebt(MEMORY);
        uint256 kyznOut = k * WITHDRAW_BPS / BPS;
        uint256 usdgOut = u * WITHDRAW_BPS / BPS;
        vm.startBroadcast(s.deployer);
        s.vault.withdraw(MEMORY, kyznOut, usdgOut);
        vm.stopBroadcast();
        console2.log("kMEMORY withdrew $KYZN        ", _units(kyznOut));
        console2.log("  withdrew USDG               ", _units(_usd(s, usdgOut)));
    }

    function _fabPosition(Silicon memory s, uint256 kyznIn, uint256 kyznPrice) private {
        Opening memory o = _size(s, FAB, kyznIn, kyznPrice, FAB_RATIO_BPS);
        uint256 minimum = s.vault.market(FAB).minDebt;
        if (o.mint < minimum) revert MintTooSmall(FAB, o.mint, minimum);
        vm.startBroadcast(s.deployer);
        _deposit(s, FAB, o);
        s.vault.mint(FAB, o.mint);
        vm.stopBroadcast();
        console2.log("kFAB deposited $KYZN          ", _units(o.kyzn));
        console2.log("  deposited USDG              ", _units(_usd(s, o.usdg)));
        console2.log("  minted                      ", _units(o.mint));
    }

    /// Mints at least `shortfall` kFAB on a fresh position at about 160%, 60% $KYZN.
    function _mintForBid(Silicon memory s, uint256 shortfall) private {
        (,, uint256 shares) = s.vault.positions(FAB, s.deployer);
        uint256 amount = shares == 0 ? Math.max(shortfall, s.vault.market(FAB).minDebt) : shortfall;
        (uint256 synthPrice,) = s.feeds[FAB].latestPrice();
        uint256 fee = Math.mulDiv(amount, s.vault.market(FAB).mintFeeBps, BPS, Math.Rounding.Ceil);
        uint256 debtValue = Math.mulDiv(amount + fee, synthPrice, 1e18, Math.Rounding.Ceil);
        uint256 collateral = debtValue * BIDDER_RATIO_BPS / BPS;
        uint256 kyznValue = collateral * KYZN_SHARE_BPS / BPS;
        Opening memory o;
        o.kyzn = Math.mulDiv(kyznValue, 1e18, s.oracle.price(), Math.Rounding.Ceil);
        o.usdg = (collateral - kyznValue) / s.vault.usdgScale();
        o.mint = amount;
        uint256 held = s.kyzn.balanceOf(s.deployer);
        if (o.kyzn > held) revert NotEnoughKyzn(held, o.kyzn);
        vm.startBroadcast(s.deployer);
        _deposit(s, FAB, o);
        s.vault.mint(FAB, amount);
        vm.stopBroadcast();
        console2.log("kFAB minted for the bid       ", _units(amount));
        console2.log("  against $KYZN               ", _units(o.kyzn));
        console2.log("  and USDG                    ", _units(_usd(s, o.usdg)));
    }

    /// What a position in market `id` takes for `kyznIn` $KYZN: USDG for KYZN_SHARE_BPS $KYZN by
    /// value, and the mint (the fee on top) that puts the whole position at `ratioBps`.
    function _size(Silicon memory s, uint256 id, uint256 kyznIn, uint256 kyznPrice, uint256 ratioBps)
        private
        view
        returns (Opening memory o)
    {
        o.kyzn = kyznIn;
        uint256 usdgScale = s.vault.usdgScale();
        o.usdg = Math.mulDiv(kyznIn, kyznPrice, 1e18) * (BPS - KYZN_SHARE_BPS) / KYZN_SHARE_BPS / usdgScale;
        (uint256 kyznHeld, uint256 usdgHeld,) = s.vault.positions(id, s.deployer);
        uint256 kyznValue = Math.mulDiv(kyznHeld + o.kyzn, kyznPrice, 1e18);
        uint256 collateral = kyznValue + (usdgHeld + o.usdg) * usdgScale;
        if (kyznValue * BPS / collateral < 5_000) revert KyznShareTooLow(id, kyznValue * BPS / collateral);
        (uint256 synthPrice,) = s.feeds[id].latestPrice();
        uint256 debt = Math.mulDiv(collateral * BPS / ratioBps, 1e18, synthPrice);
        o.mint = debt * BPS / (BPS + s.vault.market(id).mintFeeBps);
    }

    function _deposit(Silicon memory s, uint256 id, Opening memory o) private {
        s.kyzn.forceApprove(address(s.vault), o.kyzn);
        IERC20(address(s.usdg)).forceApprove(address(s.vault), o.usdg);
        s.vault.deposit(id, o.kyzn, o.usdg);
    }

    /// Repays in full when the deployer's synth covers the debt, otherwise down to the minimum
    /// debt; then withdraws everything from a position that owes nothing. Inside a broadcast.
    function _restorePosition(Silicon memory s, uint256 id) private {
        uint256 debt = s.vault.debtOf(id, s.deployer);
        uint256 held = s.synths[id].balanceOf(s.deployer);
        if (debt != 0 && held != 0) {
            uint256 minimum = s.vault.market(id).minDebt;
            // A full repay asks for a little more than the debt read now, which grows by the
            // borrow fee until the transaction lands; a part payment leaves the minimum.
            uint256 amount = held > debt + debt / 1e6 + 1 ? held : (debt > minimum ? Math.min(held, debt - minimum) : 0);
            if (amount != 0) {
                s.vault.repay(id, amount);
                console2.log(string.concat(s.symbols[id], " repaid"), _units(Math.min(amount, debt)));
            }
        }
        (uint256 k, uint256 u, uint256 shares) = s.vault.positions(id, s.deployer);
        if (shares == 0 && (k != 0 || u != 0)) {
            s.vault.withdraw(id, k, u);
            console2.log(string.concat(s.symbols[id], " withdrew $KYZN"), _units(k));
            console2.log("  and USDG                    ", _units(_usd(s, u)));
        } else if (shares != 0) {
            console2.log(string.concat(s.symbols[id], " still owes"), _units(s.vault.debtOf(id, s.deployer)));
        }
    }

    /// The running auction of the deployer's position in market `id`, among the latest.
    function _runningAuction(Silicon memory s, uint256 id) private view returns (uint256, bool) {
        uint256 count = s.vault.auctionCount();
        uint256 floor = count > AUCTION_LOOKBACK ? count - AUCTION_LOOKBACK : 0;
        for (uint256 k = count; k > floor; --k) {
            SiliconVault.Auction memory a = s.vault.auction(k - 1);
            if (a.account == s.deployer && a.marketId == id) return (k - 1, true);
        }
        return (0, false);
    }

    // ================================================================ prices and checks

    function _stamp(TestnetFeed f, string memory name) private {
        (, int256 answer,,,) = f.latestRoundData();
        f.set(answer, block.timestamp);
        console2.log(string.concat(name, " stamped (1e8)"), answer);
    }

    function _requireWindow(Silicon memory s) private view {
        if (!s.calendar.isMintWindow(block.timestamp)) revert OutsideWindow(block.timestamp);
    }

    function _requireFresh(Silicon memory s, uint256 id) private view {
        if (!s.feeds[id].isFresh()) revert NotFresh(address(s.feeds[id]));
    }

    function _logRevert(bytes memory reason) private pure {
        // The first four bytes of a revert are its selector.
        // forge-lint: disable-next-line(unsafe-typecast)
        bytes4 selector = reason.length >= 4 ? bytes4(reason) : bytes4(0);
        if (selector == SiliconVault.StalePrice.selector && reason.length == 36) {
            address feed;
            assembly ("memory-safe") {
                feed := mload(add(reason, 36))
            }
            console2.log("  StalePrice(feed)            ", feed);
        } else if (selector == SiliconVault.CollateralRatioTooLow.selector) {
            console2.log("  CollateralRatioTooLow");
        } else if (selector == SiliconVault.DebtBelowMinimum.selector) {
            console2.log("  DebtBelowMinimum");
        } else {
            console2.logBytes(reason);
        }
    }

    /// WETH per 1e18 $KYZN at the pool's spot price.
    function _spot(Silicon memory s) private view returns (uint256) {
        (uint112 r0, uint112 r1,) = ITestnetUniswapV2Pair(s.pair).getReserves();
        bool kyznFirst = ITestnetUniswapV2Pair(s.pair).token0() == address(s.kyzn);
        return kyznFirst ? Math.mulDiv(r1, 1e18, r0) : Math.mulDiv(r0, 1e18, r1);
    }

    function _usd(Silicon memory s, uint256 usdgAmount) private view returns (uint256) {
        return usdgAmount * s.vault.usdgScale();
    }

    function _abs(int256 x) private pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _ticker(Silicon memory s, string memory ticker) private pure returns (uint256) {
        for (uint256 i; i < STOCKS; ++i) {
            if (keccak256(bytes(s.tickers[i])) == keccak256(bytes(ticker))) return i;
        }
        revert UnknownTicker(ticker);
    }

    function _symbol(Silicon memory s, string memory symbol) private pure returns (uint256) {
        for (uint256 id; id < MARKETS; ++id) {
            if (keccak256(bytes(s.symbols[id])) == keccak256(bytes(symbol))) return id;
        }
        revert UnknownSymbol(symbol);
    }

    // ================================================================ status

    function _status(Silicon memory s) private view {
        console2.log("---- status at                ", block.timestamp);
        console2.log("Mint window open              ", s.calendar.isMintWindow(block.timestamp));
        try s.oracle.price() returns (uint256 price) {
            console2.log("$KYZN/USD (1e18)              ", price);
        } catch {
            console2.log("$KYZN/USD                      unavailable");
        }
        console2.log("Deployer ETH                  ", _units(s.deployer.balance));
        console2.log("Deployer $KYZN                ", _units(s.kyzn.balanceOf(s.deployer)));
        console2.log("Deployer USDG                 ", _units(_usd(s, s.usdg.balanceOf(s.deployer))));
        for (uint256 id; id < MARKETS; ++id) {
            _marketStatus(s, id);
        }
    }

    function _marketStatus(Silicon memory s, uint256 id) private view {
        SiliconVault.Market memory m = s.vault.market(id);
        (uint256 price,) = s.feeds[id].latestPrice();
        console2.log(string.concat(s.symbols[id], " index (USD)"), _units(price));
        console2.log("  open / fresh for mints      ", m.open, s.feeds[id].isFresh());
        console2.log("  fresh for liquidation       ", s.feeds[id].isFreshForLiquidation());
        console2.log("  minDebt                     ", _units(m.minDebt));
        console2.log("  bad debt                    ", _units(m.badDebt));
        console2.log("  deployer holds              ", _units(s.synths[id].balanceOf(s.deployer)));
        (uint256 k, uint256 u, uint256 shares) = s.vault.positions(id, s.deployer);
        if (k == 0 && u == 0 && shares == 0) return;
        console2.log("  position $KYZN              ", _units(k));
        console2.log("  position USDG               ", _units(_usd(s, u)));
        console2.log("  position debt               ", _units(s.vault.debtOf(id, s.deployer)));
        if (shares == 0) return;
        try s.vault.health(id, s.deployer) returns (uint256, uint256, uint256 ratio, uint256 share) {
            console2.log("  ratio / $KYZN share (bps)   ", ratio, share);
        } catch {
            console2.log("  ratio                        unavailable");
        }
    }

    // ================================================================ the deployment

    /// The Silicon deployment from deployments/46630.json, checked against the contracts; the
    /// sender must be its deployer.
    function _silicon() private view returns (Silicon memory s) {
        s = _load46630();
        if (msg.sender != s.deployer) revert NotDeployer(msg.sender, s.deployer);
    }

    /// The Silicon deployment from deployments/46630.json, checked against the contracts.
    function _load46630() private view returns (Silicon memory s) {
        _checkChain();
        // Reads only deployments/, which foundry.toml's fs_permissions allow.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(SILICON_DEPLOYMENT);
        s.deployer = vm.parseJsonAddress(json, ".deployer");
        s.kyzn = IERC20(vm.parseJsonAddress(json, ".kyznToken"));
        s.pair = vm.parseJsonAddress(json, ".kyznWethPair");
        s.router = vm.parseJsonAddress(json, ".uniswapV2Router02");
        s.ethUsd = TestnetFeed(vm.parseJsonAddress(json, ".ethUsdFeed"));
        s.vault = SiliconVault(vm.parseJsonAddress(json, ".silicon.vault"));
        s.oracle = KyznUsdOracle(vm.parseJsonAddress(json, ".silicon.oracle"));
        s.calendar = MarketCalendar(vm.parseJsonAddress(json, ".silicon.calendar"));
        s.usdg = TestnetUsdg(vm.parseJsonAddress(json, ".silicon.usdg"));
        s.tickers = ["NVDA", "AMD", "MU", "SNDK", "TSM", "INTC", "ASML"];
        for (uint256 i; i < STOCKS; ++i) {
            s.stocks[i] = TestnetFeed(vm.parseJsonAddress(json, string.concat(".silicon.stockFeeds.", s.tickers[i])));
        }
        for (uint256 id; id < MARKETS; ++id) {
            string memory path = string.concat(".silicon.markets[", vm.toString(id), "]");
            s.symbols[id] = vm.parseJsonString(json, string.concat(path, ".symbol"));
            s.synths[id] = SiliconSynth(vm.parseJsonAddress(json, string.concat(path, ".synth")));
            s.feeds[id] = StockIndexFeed(vm.parseJsonAddress(json, string.concat(path, ".feed")));
            s.minDebt[id] = vm.parseUint(vm.parseJsonString(json, string.concat(path, ".minDebt")));
            s.debtCeiling[id] = vm.parseUint(vm.parseJsonString(json, string.concat(path, ".debtCeiling")));
            SiliconVault.Market memory m = s.vault.market(id);
            if (address(m.synth) != address(s.synths[id]) || address(m.feed) != address(s.feeds[id])) {
                revert DeploymentMismatch(s.symbols[id]);
            }
        }
        if (address(s.vault.oracle()) != address(s.oracle) || address(s.vault.kyzn()) != address(s.kyzn)) {
            revert DeploymentMismatch("vault");
        }
        if (address(s.vault.usdg()) != address(s.usdg)) revert DeploymentMismatch("usdg");
    }
}
