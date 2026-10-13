// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Vm} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Reserve} from "../../src/Reserve.sol";
import {Staking} from "../../src/Staking.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {KyznUsdOracle} from "../../src/silicon/KyznUsdOracle.sol";
import {MarketCalendar} from "../../src/silicon/MarketCalendar.sol";
import {SiliconFeeRouter} from "../../src/silicon/SiliconFeeRouter.sol";
import {SiliconSynth} from "../../src/silicon/SiliconSynth.sol";
import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {StockIndexFeed} from "../../src/silicon/StockIndexFeed.sol";
import {SiliconDeployment, SiliconMainnet, SiliconMainnetTerms as Terms} from "../../script/SiliconMainnet.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";
import {SiliconMainnetOpen} from "../../script/SiliconMainnetOpen.s.sol";
import {SiliconMainnetFork} from "./utils/SiliconMainnetFork.sol";
import {SiliconSwapAdapter} from "../../src/silicon/SiliconSwapAdapter.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IV4Quoter, QuoteExactSingleParams} from "../../script/interfaces/IUniswapV4.sol";
import {SiliconPoolSeed as Seed} from "../../script/lib/SiliconPoolSeed.sol";

/// Uniswap v3 QuoterV2's single-pool quote.
interface ISiliconQuoterV2 {
    struct QuoteExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint256 amountIn;
        uint24 fee;
        uint160 sqrtPriceLimitX96;
    }

    function quoteExactInputSingle(QuoteExactInputSingleParams memory params)
        external
        returns (uint256 amountOut, uint160 sqrtPriceX96After, uint32 initializedTicksCrossed, uint256 gasEstimate);
}

/// The Silicon stock indices' mainnet deployment (script/SiliconMainnet.sol), rehearsed on a fork
/// of Robinhood Chain mainnet against the real $KYZN, pair, USDG, Reserve, Staking, WETH and
/// Chainlink feeds, from the real owner wallet:
///   1. the deployment as the owner sends it: every address, level, calendar day, methodology,
///      guardian, feed component and ownership offer, the gas and the code sizes;
///   2. only the owner wallet, and only on Robinhood Chain, can deploy it;
///   3. the path after the launch: the owner's liquidity, the deployment, the owner accepting, Staking
///      naming the fee router, 24 hours of the worker's oracle updates, the four markets opened,
///      then in Monday's minting window a mint with real USDG, a repay and a withdrawal;
///   4. the auction floor at 76%: a position minted at exactly 150% and auctioned by its own
///      borrower one second later cannot get its collateral back for less than its debt.
/// See SiliconMainnetFork for what the fork stands in for. The deployment's creation code is about
/// 55 KB, over Ethereum's 48 KB limit and within Robinhood Chain's 96 KB; forge test runs it as it
/// is (forge script and anvil need --disable-code-size-limit). `--isolate` logs each owner
/// transaction's gas as its receipt would show it, before the chain's data fee.
///   ROBINHOOD_RPC_URL=http://127.0.0.1:8552 forge test --match-path "test/fork/*SiliconMainnet*" -vv
contract SiliconMainnetForkTest is SiliconMainnetFork {
    /// The v3 USDG/WETH pool the adapter sells into: 0.01%, the deepest USDG pool on the chain.
    uint24 internal constant V3_USDG_WETH_FEE = 100;

    address internal minter = makeAddr("minter");
    address internal helper = makeAddr("helper");
    address internal borrower = makeAddr("borrower");
    address internal stranger = makeAddr("stranger");
    /// The collateral of test 4's borrower.
    uint256 internal borrowerKyzn;
    uint256 internal borrowerUsdg;

    function setUp() public {
        _fork();
    }

    // ---------------------------------------------------------------- 1. the deployment

    function test_1_the_deployment_is_every_address_and_level_of_spec_3_5() public {
        uint256 forkBlock = block.number;
        _deploy();
        _logSizesAndGas();
        _assertDeployedEvent(forkBlock);

        // Each contract is offered to the owner wallet, not yet its own.
        address[7] memory owned = _owned();
        for (uint256 i; i < owned.length; ++i) {
            assertEq(Ownable(owned[i]).owner(), address(deployment), "owned by the deployment until accepted");
            assertEq(Ownable2Step(owned[i]).pendingOwner(), OWNER, "offered to the owner wallet");
        }
        uint256[7] memory acceptGas = _acceptAll();
        string[7] memory names =
            ["calendar", "vault", "fee router", "kDESIGN feed", "kMEMORY feed", "kFAB feed", "kEQUIP feed"];
        for (uint256 i; i < owned.length; ++i) {
            assertEq(Ownable(owned[i]).owner(), OWNER, names[i]);
            assertEq(Ownable2Step(owned[i]).pendingOwner(), address(0), names[i]);
            emit log_named_uint(string.concat("  acceptOwnership gas, ", names[i]), acceptGas[i]);
        }

        _assertTermsMatchTheChain();
        _assertCalendar();
        _assertOracle();
        _assertFeeRouter();
        _assertSwapAdapterQueued();
        _assertVault();
        for (uint256 id; id < MARKETS; ++id) {
            _assertMarket(id);
        }

        // Nothing is open: a mint is refused, and only the owner can open a market.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SiliconVault.MarketNotOpen.selector, 0));
        vault.mint(0, 1e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.openMarket(0);
    }

    // ---------------------------------------------------------------- 2. who and where

    function test_2_only_the_owner_wallet_deploys_it_and_only_on_robinhood_chain() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SiliconDeployment.NotOwner.selector, stranger, OWNER));
        new SiliconMainnet();

        vm.chainId(1);
        vm.prank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(SiliconDeployment.WrongChain.selector, 1));
        new SiliconMainnet();
    }

    // ---------------------------------------------------------------- 3. after the launch

    function test_3_after_the_launch_the_owner_opens_and_a_user_mints_repays_and_withdraws() public {
        _addLiquidity();
        (uint112 r0, uint112 r1,) = POOL.getReserves();
        assertGt(uint256(r0) * r1, 0, "the pool has liquidity");
        _deploy();
        _acceptAll();
        // The opening check: owned, but no fee source and no $KYZN price yet.
        SiliconMainnetOpen check = new SiliconMainnetOpen();
        SiliconMainnetOpen.Status memory st = check.status(vault, OWNER);
        assertTrue(st.accepted);
        assertFalse(st.feeSource);
        assertFalse(st.priced);
        for (uint256 id; id < MARKETS; ++id) {
            assertTrue(st.settingsSet[id]);
            assertFalse(check.canOpen(st, id));
        }
        _assertStakingTakesTheFeeRouter();

        // No $KYZN price until the long window has passed with the worker's hourly observations.
        uint256 t0 = block.timestamp;
        vm.expectRevert(abi.encodeWithSelector(KyznUsdOracle.TwapNotReady.selector, t0 + 1 days));
        oracle.price();
        _advance(t0 + 1 days);
        assertTrue(feeRouter.isTargetAllowed(address(swapAdapter)), "the adapter is live 24 hours after deployment");
        uint256 kyznUsd = oracle.price();
        assertEq(kyznUsd, _expectedKyznUsd(), "the 1-hour and 24-hour averages of a still pool are its price");
        assertEq(oracle.observationCount(), 25, "one observation at deployment, then one an hour");
        emit log_named_decimal_uint("$KYZN in USD after 24 hours", kyznUsd, 18);

        // The check now: priced, and each market opens only with its ceiling within the pool's depth.
        st = check.status(vault, OWNER);
        assertTrue(st.feeSource);
        assertTrue(st.indicesLive, "every index prices and is fresh to liquidate on");
        assertTrue(st.priced);
        assertEq(st.kyznUsd, kyznUsd);
        assertEq(st.depthUsd, Math.mulDiv(_poolKyzn(), kyznUsd, 1e18));
        emit log_named_decimal_uint("pool depth in USD, $KYZN side", st.depthUsd, 18);
        uint256 total;
        for (uint256 id; id < MARKETS; ++id) {
            emit log_named_decimal_uint("debt ceiling in USD", st.ceilingUsd[id], 18);
            assertApproxEqAbs(st.ceilingUsd[id], 25_000e18, 1e6);
            assertEq(check.canOpen(st, id), st.ceilingUsd[id] <= st.depthUsd);
            if (check.canOpen(st, id)) total += st.ceilingUsd[id];
        }
        assertEq(st.totalCeilingUsd, total, "the ceilings of the markets that may open, summed");
        emit log_named_decimal_uint("ceilings of the markets that may open, summed (USD)", total, 18);
        check.report(vault, OWNER);

        // The rehearsal opens the four markets as the owner would once the check passes.
        uint256[4] memory openGas = _openAll();
        for (uint256 id; id < MARKETS; ++id) {
            emit log_named_uint("openMarket gas", openGas[id]);
        }
        assertEq(vault.openMarketCount(), MARKETS);
        st = check.status(vault, OWNER);
        total = 0;
        for (uint256 id; id < MARKETS; ++id) {
            assertTrue(vault.market(id).open);
            assertTrue(st.open[id]);
            assertFalse(check.canOpen(st, id));
            total += st.ceilingUsd[id];
        }
        assertEq(st.totalCeilingUsd, total, "the open markets' ceilings, summed");
        _assertRiskSettingsNowWait();

        // Monday 15:00 UTC, a regular day: every index is fresh for a mint.
        uint256 window = _mondayWindow(block.timestamp);
        _advance(window);
        assertTrue(calendar.isMintWindow(block.timestamp));
        for (uint256 id; id < MARKETS; ++id) {
            assertTrue(feeds[id].isFresh(), "fresh in the window");
        }

        // A user deposits $700 of $KYZN and $500 of USDG and mints 6 kDESIGN (about $600).
        kyznUsd = oracle.price();
        uint256 kyznAmount = Math.mulDiv(700e18, 1e18, kyznUsd);
        uint256 usdgAmount = 500e6;
        _fund(minter, kyznAmount, usdgAmount);
        assertEq(USDG.balanceOf(minter), usdgAmount, "USDG funded");
        vm.startPrank(minter);
        vault.deposit(0, kyznAmount, usdgAmount);
        vault.mint(0, 6e18);
        vm.stopPrank();
        emit log_named_uint("mint gas (execution)", vm.lastCallGas().gasTotalUsed);
        uint256 fee = Math.mulDiv(6e18, Terms.MINT_FEE_BPS, 10_000, Math.Rounding.Ceil);
        assertEq(synths[0].balanceOf(minter), 6e18);
        assertEq(synths[0].balanceOf(address(feeRouter)), fee, "the 0.5% mint fee, to the fee router");
        assertEq(vault.debtOf(0, minter), 6e18 + fee);
        (uint256 collateralValue, uint256 debtValue, uint256 ratio, uint256 kyznShare) = vault.health(0, minter);
        emit log_named_decimal_uint("collateral (USD)", collateralValue, 18);
        emit log_named_decimal_uint("debt (USD)", debtValue, 18);
        emit log_named_uint("collateral ratio (bps)", ratio);
        assertGe(ratio, 15_000);
        assertGe(kyznShare, 5_000);

        // An hour later the 12% borrow fee has accrued; the user repays all of it (synth from a
        // second position, as from a market) and withdraws everything, at no price.
        _advance(window + 1 hours);
        assertGt(vault.debtOf(0, minter), 6e18 + fee, "the borrow fee accrues");
        _fund(helper, kyznAmount, usdgAmount);
        vm.startPrank(helper);
        vault.deposit(0, kyznAmount, usdgAmount);
        vault.mint(0, 6e18);
        synths[0].transfer(minter, 1e18);
        vm.stopPrank();
        // Read after the helper's mint, which rounds its own shares up (the minter's debt may read
        // a wei lower).
        uint256 debt = vault.debtOf(0, minter);
        vm.startPrank(minter);
        assertEq(vault.repay(0, synths[0].balanceOf(minter)), debt, "repaid in full");
        vault.withdraw(0, kyznAmount, usdgAmount);
        vm.stopPrank();
        assertEq(vault.debtOf(0, minter), 0);
        assertEq(TOKEN.balanceOf(minter), kyznAmount, "every $KYZN back");
        assertEq(USDG.balanceOf(minter), usdgAmount, "every USDG back");

        // Every synth in circulation is owed to the vault.
        vault.drip(0);
        SiliconVault.Market memory m = vault.market(0);
        assertEq(synths[0].totalSupply(), m.totalDebt + m.auctionDebt + m.badDebt);
    }

    // ---------------------------------------------------------------- 4. the floor

    function test_4_the_76_percent_floor_leaves_no_gain_in_liquidating_your_own_position() public {
        uint256 auctionId = _ownAuctionAtExactly150();
        SiliconVault.Auction memory a = vault.auction(auctionId);
        assertEq(a.kyzn, borrowerKyzn);
        assertEq(a.usdg, borrowerUsdg);
        assertEq(a.penalty, Math.mulDiv(a.debt, Terms.LIQUIDATION_PENALTY_BPS, 10_000), "the 13% penalty");

        // No one else bids. In its last second the lot is at its floor, 76% of the collateral's
        // oracle value, and still worth more than the auction is owed: 0.76 x 150% = 114% of the
        // debt, above the 113% of debt and penalty.
        vm.warp(a.startedAt + a.duration - 1);
        uint256 lot = vault.auctionPrice(auctionId);
        emit log_named_decimal_uint("debt (synth)", a.debt, 18);
        emit log_named_decimal_uint("debt + penalty (synth)", a.debt + a.penalty, 18);
        emit log_named_decimal_uint("whole lot at the floor (synth)", lot, 18);
        assertGe(lot, a.debt + a.penalty, "the floor is above the debt and the penalty");
        // At the old 40% floor the same lot would have sold whole for 60% of the debt.
        assertLt(Math.mulDiv(lot, 4_000, Terms.AUCTION_FLOOR_BPS), a.debt);
        // The borrower holds the synth for every bid below.
        uint256 topUp = a.debt + a.penalty - synths[0].balanceOf(borrower);
        vm.prank(helper);
        synths[0].transfer(borrower, topUp);

        uint256 snapshot = vm.snapshotState();
        _bidForTheWholeLot(auctionId, a);
        vm.revertToState(snapshot);
        snapshot = vm.snapshotState();
        _bidTheDebtThenClose(auctionId, a);
        vm.revertToState(snapshot);
        _bidLessThanTheDebt(auctionId, a);
    }

    /// The borrower's own auction of its position, minted at exactly 150% in Monday's window and
    /// put up one second later, once the borrow fee has taken it below.
    function _ownAuctionAtExactly150() internal returns (uint256 auctionId) {
        _launchAndOpenInTheWindow();
        uint256 kyznUsd = oracle.price();
        (uint256 synthUsd,) = feeds[0].latestPrice();

        // A second position, minted first, supplies synth for the bids (as a market would).
        _fund(helper, Math.mulDiv(3_000e18, 1e18, kyznUsd), 2_000e6);
        vm.startPrank(helper);
        vault.deposit(0, TOKEN.balanceOf(helper), USDG.balanceOf(helper));
        vault.mint(0, 20e18);
        vm.stopPrank();

        // The borrower: $1,000 of $KYZN and $800 of USDG, and the largest mint the vault allows,
        // which leaves it at exactly 150%.
        borrowerKyzn = Math.mulDiv(1_000e18, 1e18, kyznUsd);
        borrowerUsdg = 800e6;
        _fund(borrower, borrowerKyzn, borrowerUsdg);
        vm.prank(borrower);
        vault.deposit(0, borrowerKyzn, borrowerUsdg);
        uint256 amount = _largestMint(borrowerKyzn, borrowerUsdg, kyznUsd, synthUsd);
        uint256 snapshot = vm.snapshotState();
        vm.prank(borrower);
        vm.expectRevert(); // one wei more is below 150%
        vault.mint(0, amount + 1);
        vm.revertToState(snapshot);
        vm.prank(borrower);
        vault.mint(0, amount);
        (,, uint256 ratio,) = vault.health(0, borrower);
        assertEq(ratio, 15_000, "exactly 150%");

        vm.warp(block.timestamp + 1);
        _freshFeeds();
        (,, ratio,) = vault.health(0, borrower);
        assertLt(ratio, 15_000, "one second of borrow fee");
        vm.prank(borrower);
        auctionId = vault.startAuction(borrower, 0);
    }

    /// A. One bid for the whole lot: it pays the debt and the penalty, and gets every unit back
    /// (the bid's share, and the rest to the position as the auction closes).
    function _bidForTheWholeLot(uint256 auctionId, SiliconVault.Auction memory a) internal {
        uint256 routerBefore = synths[0].balanceOf(address(feeRouter));
        vm.prank(borrower);
        (uint256 paid, uint256 kyznOut, uint256 usdgOut) = vault.bid(auctionId, type(uint256).max);
        assertEq(paid, a.debt + a.penalty, "paid the debt and the penalty");
        assertEq(synths[0].balanceOf(address(feeRouter)) - routerBefore, a.penalty, "the penalty, to the fee router");
        _assertCollateralBack(auctionId, kyznOut, usdgOut);
    }

    /// B. The cheapest way back: a bid of exactly the debt, then the close after the end, which
    /// returns the rest to the position and waives the penalty no bid covered. It pays the debt,
    /// as a repayment would: no gain.
    function _bidTheDebtThenClose(uint256 auctionId, SiliconVault.Auction memory a) internal {
        vm.prank(borrower);
        (uint256 paid, uint256 kyznOut, uint256 usdgOut) = vault.bid(auctionId, a.debt);
        assertEq(paid, a.debt);
        assertLt(kyznOut, borrowerKyzn, "the debt alone buys part of the lot");
        vm.warp(a.startedAt + a.duration);
        vault.closeAuction(auctionId);
        _assertCollateralBack(auctionId, kyznOut, usdgOut);
    }

    /// C. Less than the debt never brings it back: the auction restarts at fresh prices with the
    /// rest of the collateral, and the position stays empty.
    function _bidLessThanTheDebt(uint256 auctionId, SiliconVault.Auction memory a) internal {
        vm.prank(borrower);
        vault.bid(auctionId, a.debt - 1);
        vm.warp(a.startedAt + a.duration);
        _freshFeeds();
        vault.closeAuction(auctionId);
        assertTrue(vault.auction(auctionId).restarted, "restarted, not returned");
        (uint256 kyznLeft, uint256 usdgLeft,) = vault.positions(0, borrower);
        assertEq(kyznLeft + usdgLeft, 0, "nothing back to the position");
    }

    // ---------------------------------------------------------------- 5. the swap adapter

    /// The swap adapter the deployment queued is the fee router's target 24 hours later, with
    /// nothing more sent, and the keeper sells fee synth and USDG through it. Kept short, apart
    /// from test 3, so that its many first reads of Uniswap's state come while the fork's block is
    /// still served: the fee synth is dealt to the router here (the vault mints it in test 3).
    function test_5_the_fee_router_sells_through_the_adapter_24_hours_after_the_deployment() public {
        _deploy();
        _acceptAll();
        vm.prank(OWNER);
        Staking(payable(Terms.STAKING)).setFeeSource(address(feeRouter));
        deal(address(synths[0]), address(feeRouter), 0.06e18);
        deal(address(synths[0]), helper, 4e18);

        bytes memory data = abi.encodeCall(SiliconSwapAdapter.sellUsdg, (1e6, V3_USDG_WETH_FEE));
        vm.prank(Terms.KEEPER);
        vm.expectRevert(SiliconFeeRouter.BadTarget.selector);
        feeRouter.convert(Terms.USDG, address(swapAdapter), data, 1e6, 0);

        vm.warp(block.timestamp + 24 hours);
        assertTrue(feeRouter.isTargetAllowed(address(swapAdapter)));
        _assertTheKeeperSellsTheFeesThroughTheAdapter();
    }

    // ---------------------------------------------------------------- the deployment's checks

    function _logSizesAndGas() internal {
        uint256 initcode = type(SiliconMainnet).creationCode.length;
        emit log_named_uint("SiliconMainnet creation code (bytes)", initcode);
        emit log_named_uint("SiliconMainnet runtime (bytes)", address(deployment).code.length);
        emit log_named_uint("SiliconVault runtime (bytes)", address(vault).code.length);
        emit log_named_uint("StockIndexFeed runtime (bytes)", address(feeds[0]).code.length);
        emit log_named_uint("KyznUsdOracle runtime (bytes)", address(oracle).code.length);
        emit log_named_uint("SiliconFeeRouter runtime (bytes)", address(feeRouter).code.length);
        emit log_named_uint("SiliconSwapAdapter runtime (bytes)", address(swapAdapter).code.length);
        emit log_named_uint(
            _isolated() ? "deployment gas (receipt, before the data fee)" : "deployment gas (estimate)", deployGas
        );
        assertLe(initcode, 96 * 1024, "Robinhood Chain accepts up to 96 KB");
        assertLe(address(vault).code.length, 24_576, "the vault fits Ethereum's runtime limit");
        assertLt(deployGas, 32_000_000, "one transaction");
    }

    /// The one Deployed event: every address and the chain's block number.
    function _assertDeployedEvent(uint256 forkBlock) internal view {
        uint256 found;
        for (uint256 i; i < deployLogs.length; ++i) {
            Vm.Log memory l = deployLogs[i];
            if (l.topics[0] != SiliconDeployment.Deployed.selector) continue;
            ++found;
            assertEq(l.emitter, address(deployment));
            assertEq(l.topics[1], bytes32(uint256(uint160(OWNER))));
            (
                address cal,
                address orc,
                address vlt,
                address router,
                address adapter,
                address[4] memory synthList,
                address[4] memory feedList,
                uint256 deployBlock
            ) = abi.decode(l.data, (address, address, address, address, address, address[4], address[4], uint256));
            assertEq(adapter, address(swapAdapter));
            assertEq(cal, address(calendar));
            assertEq(orc, address(oracle));
            assertEq(vlt, address(vault));
            assertEq(router, address(feeRouter));
            for (uint256 id; id < MARKETS; ++id) {
                assertEq(synthList[id], address(synths[id]));
                assertEq(feedList[id], address(feeds[id]));
                assertEq(address(vault.market(id).synth), address(synths[id]));
                assertEq(address(vault.market(id).feed), address(feeds[id]));
            }
            assertEq(deployBlock, forkBlock, "the chain's block number, from ArbSys");
            assertEq(deployment.deployBlock(), forkBlock);
        }
        assertEq(found, 1, "one Deployed event");
        assertEq(deployment.owner(), OWNER);
    }

    /// The terms are the chain's and deployments/4663.json's.
    function _assertTermsMatchTheChain() internal view {
        string memory json = vm.readFile("deployments/4663.json");
        assertEq(vm.parseJsonAddress(json, ".deployer"), Terms.OWNER, "the owner wallet");
        assertEq(vm.parseJsonAddress(json, ".keeper"), Terms.KEEPER, "the recorded keeper");
        assertEq(vm.parseJsonAddress(json, ".reserve"), Terms.RESERVE);
        assertEq(vm.parseJsonAddress(json, ".staking"), Terms.STAKING);
        assertEq(vm.parseJsonAddress(json, ".kyznToken"), Terms.KYZN);
        assertEq(vm.parseJsonAddress(json, ".kyznWethPair"), Terms.PAIR);
        assertEq(vm.parseJsonAddress(json, ".weth"), RH.WETH);
        assertEq(vm.parseJsonAddress(json, ".ethUsdFeed"), RH.ETH_USD_FEED);

        assertEq(TOKEN.pair(), Terms.PAIR);
        address tokenOwner = TOKEN.owner();
        if (tokenOwner != address(0)) assertEq(tokenOwner, OWNER, "the token's owner, until it renounces");
        assertEq(Reserve(payable(Terms.RESERVE)).owner(), OWNER);
        assertEq(Staking(payable(Terms.STAKING)).owner(), OWNER);
        assertEq(Reserve(payable(Terms.RESERVE)).keeper(), Terms.KEEPER, "the Reserve's keeper");
        assertEq(address(Reserve(payable(Terms.RESERVE)).kyzn()), Terms.KYZN);
        assertEq(address(Staking(payable(Terms.STAKING)).kyzn()), Terms.KYZN);

        assertGt(Terms.USDG.code.length, 0, "USDG is a contract");
        assertEq(IERC20Metadata(Terms.USDG).decimals(), 6);
        assertEq(IERC20Metadata(Terms.USDG).symbol(), "USDG");
    }

    /// Every day of script/market-calendar.json, marked on chain, and the window on sample days.
    function _assertCalendar() internal view {
        string memory json = vm.readFile("script/market-calendar.json");
        uint256[] memory closed = abi.decode(vm.parseJson(json, ".closed[*].day"), (uint256[]));
        uint256[] memory early = abi.decode(vm.parseJson(json, ".earlyClose[*].day"), (uint256[]));
        assertEq(Terms.closedDays(), closed, "the closed days are the file's");
        assertEq(Terms.earlyCloseDays(), early, "the early closes are the file's");
        assertEq(closed.length, 21);
        assertEq(early.length, 5);
        for (uint256 i; i < closed.length; ++i) {
            assertEq(uint8(calendar.dayKind(closed[i])), uint8(MarketCalendar.DayKind.Closed));
        }
        for (uint256 i; i < early.length; ++i) {
            assertEq(uint8(calendar.dayKind(early[i])), uint8(MarketCalendar.DayKind.EarlyClose));
        }
        uint256 daySets;
        for (uint256 i; i < deployLogs.length; ++i) {
            if (deployLogs[i].emitter == address(calendar) && deployLogs[i].topics[0] == MarketCalendar.DaySet.selector)
            {
                ++daySets;
            }
        }
        assertEq(daySets, closed.length + early.length, "one DaySet per day");

        // Thursday 26 November 2026, Thanksgiving: closed. Friday 27th: until 17:00 UTC.
        assertFalse(calendar.isMintWindow(20783 days + 15 hours));
        assertTrue(calendar.isMintWindow(20784 days + 16 hours + 59 minutes));
        assertFalse(calendar.isMintWindow(20784 days + 17 hours));
        // Saturday 28th: closed. Thursday 3 December, a regular day: 14:30 to 20:00 UTC.
        assertFalse(calendar.isMintWindow(20785 days + 15 hours));
        assertFalse(calendar.isMintWindow(20790 days + 14 hours + 29 minutes));
        assertTrue(calendar.isMintWindow(20790 days + 14 hours + 30 minutes));
        assertTrue(calendar.isMintWindow(20790 days + 19 hours + 59 minutes));
        assertFalse(calendar.isMintWindow(20790 days + 20 hours));
        // Christmas 2026 closed, Christmas Eve early, 2028's last holiday closed.
        assertEq(uint8(calendar.dayKind(20812)), uint8(MarketCalendar.DayKind.Closed));
        assertEq(uint8(calendar.dayKind(20811)), uint8(MarketCalendar.DayKind.EarlyClose));
        assertEq(uint8(calendar.dayKind(21543)), uint8(MarketCalendar.DayKind.Closed));
        assertEq(uint8(calendar.dayKind(20790)), uint8(MarketCalendar.DayKind.Regular));
    }

    function _assertOracle() internal view {
        assertEq(address(oracle.pair()), Terms.PAIR);
        assertEq(oracle.kyzn(), Terms.KYZN);
        assertEq(oracle.weth(), RH.WETH);
        assertEq(oracle.kyznIsToken0(), POOL.token0() == Terms.KYZN);
        assertEq(oracle.ethUsdFeed(), RH.ETH_USD_FEED);
        assertEq(oracle.ethUsdDecimals(), IAggregatorV3(RH.ETH_USD_FEED).decimals());
        assertEq(oracle.shortWindow(), 1 hours);
        assertEq(oracle.longWindow(), 24 hours);
        assertEq(oracle.ringSize(), 52, "2 x 24 + 4 observations");
        assertEq(oracle.observationCount(), 1, "the first at deployment");
    }

    function _assertFeeRouter() internal view {
        assertEq(address(feeRouter.weth()), RH.WETH);
        assertEq(feeRouter.reserve(), Terms.RESERVE);
        assertEq(feeRouter.staking(), Terms.STAKING);
        assertEq(feeRouter.keeper(), Terms.KEEPER);
        assertEq(feeRouter.reserveShareBps(), 6_667, "two thirds to the Reserve");
        assertTrue(feeRouter.splitSet());
    }

    /// The swap adapter on the chain's Uniswap v4 PoolManager and v3 SwapRouter02, queued as the fee
    /// router's target at deployment: live 24 hours later, with nothing more to send.
    function _assertSwapAdapterQueued() internal view {
        assertEq(address(swapAdapter.poolManager()), RH.UNISWAP_V4_POOL_MANAGER);
        assertEq(address(swapAdapter.swapRouter()), RH.UNISWAP_V3_SWAP_ROUTER_02);
        assertEq(swapAdapter.weth(), RH.WETH);
        assertEq(swapAdapter.usdg(), Terms.USDG);
        assertEq(swapAdapter.weth(), address(feeRouter.weth()), "the WETH the router counts");
        assertEq(swapAdapter.usdg(), address(vault.usdg()), "the vault's USDG");
        (bool queued, uint256 effectiveAt) = feeRouter.pendingTarget(address(swapAdapter));
        assertTrue(queued, "queued as the fee router's target");
        assertEq(effectiveAt, block.timestamp + 24 hours, "from the deployment");
        assertFalse(feeRouter.isTargetAllowed(address(swapAdapter)), "not live before its 24 hours");
    }

    function _assertVault() internal view {
        assertEq(address(vault.kyzn()), Terms.KYZN);
        assertEq(address(vault.usdg()), Terms.USDG);
        assertEq(address(vault.oracle()), address(oracle));
        assertEq(vault.usdgScale(), 1e12, "USDG's 6 decimals");
        assertEq(vault.guardian(), OWNER);
        assertEq(vault.feeRouter(), address(feeRouter));
        assertEq(vault.auctionDuration(), 6_000, "100 minutes");
        assertEq(vault.auctionStartPremiumBps(), 2_000, "from 20% above");
        assertEq(vault.auctionFloorBps(), 7_600, "never below 76%");
        assertEq(vault.marketCount(), MARKETS);
        assertEq(vault.openMarketCount(), 0);
    }

    /// Market `id`: its synth, its index feed on the real Chainlink feeds at $100, its methodology
    /// and its levels.
    function _assertMarket(uint256 id) internal {
        SiliconDeployment.Index memory x = Terms.index(id);
        string[4] memory slugs = ["kdesign", "kmemory", "kfab", "kequip"];
        string[4] memory expectedNames = ["Design", "Memory", "Fab", "Equipment"];
        string[4] memory expectedSymbols = ["kDESIGN", "kMEMORY", "kFAB", "kEQUIP"];
        assertEq(x.name, expectedNames[id]);
        assertEq(x.symbol, expectedSymbols[id]);

        SiliconSynth synth = synths[id];
        assertEq(synth.name(), string.concat("Kyzen Network ", x.name, " index"));
        assertEq(synth.symbol(), x.symbol);
        assertEq(synth.decimals(), 18);
        assertEq(synth.vault(), address(vault));
        assertEq(synth.totalSupply(), 0);
        assertTrue(vault.synthListed(address(synth)));

        StockIndexFeed feed = feeds[id];
        assertEq(feed.description(), string.concat("Kyzen Network ", x.name, " index / USD"));
        assertEq(address(feed.calendar()), address(calendar));
        assertEq(feed.guardian(), OWNER, "the guardian is the owner wallet");
        assertFalse(feed.paused());
        assertEq(feed.methodologyURI(), string.concat("https://docs.kyzen.network/methodology/", slugs[id], ".txt"));
        assertEq(feed.methodologyHash(), x.methodologyHash);
        assertTrue(feed.ready());
        address[] memory basket = x.feeds;
        assertEq(feed.componentCount(), basket.length);
        uint256 share = 100e18 / basket.length;
        for (uint256 j; j < basket.length; ++j) {
            (address component, uint8 decimals, uint256 quantity) = feed.component(j);
            assertEq(component, basket[j]);
            assertEq(decimals, 8);
            assertEq(decimals, IAggregatorV3(component).decimals());
            (uint80 round, int256 answer,,,) = IAggregatorV3(component).latestRoundData();
            // A positive answer, as the feed's constructor checked.
            // forge-lint: disable-next-line(unsafe-typecast)
            assertEq(quantity, Math.mulDiv(share, 1e18, uint256(answer) * 1e10), "equal dollar weights");
            assertEq(feed.checkedRound(j), round, "the deployment round is the reference");
            assertFalse(feed.jumped(j));
        }
        (uint256 price,) = feed.latestPrice();
        emit log_named_decimal_uint(string.concat(x.symbol, " price at deployment"), price, 18);
        assertGe(price, 99.999999e18);
        assertLe(price, 100.000001e18);

        SiliconVault.Market memory m = vault.market(id);
        assertFalse(m.open);
        assertFalse(m.mintsPaused);
        assertEq(m.mintFeeBps, 50, "0.5%");
        assertEq(m.borrowFeeBpsPerYear, 1_200, "12% a year");
        assertEq(m.liquidationPenaltyBps, 1_300, "13%");
        assertEq(m.debtCeiling, Math.mulDiv(25_000e18, 1e18, price), "$25,000 of synth, rounded down");
        assertEq(m.minDebt, Math.mulDiv(500e18, 1e18, price, Math.Rounding.Ceil), "$500 of synth, rounded up");
        assertApproxEqAbs(m.debtCeiling, 250e18, 1e12);
        assertApproxEqAbs(m.minDebt, 5e18, 1e12);
        assertEq(m.totalDebt + m.auctionDebt + m.badDebt, 0);
        assertEq(vault.unsetSettings(id), 0, "every setting set: the owner can open it");
    }

    // ---------------------------------------------------------------- the steps after

    /// Staking takes the fee router's ETH once its owner names the router its fee source.
    function _assertStakingTakesTheFeeRouter() internal {
        vm.deal(address(feeRouter), 0.3 ether);
        vm.expectRevert(SiliconFeeRouter.EthSendFailed.selector);
        feeRouter.distribute();

        vm.prank(OWNER);
        Staking(payable(Terms.STAKING)).setFeeSource(address(feeRouter));
        uint256 reserveBefore = Terms.RESERVE.balance;
        uint256 stakingBefore = Terms.STAKING.balance;
        (uint256 toReserve, uint256 toStakers) = feeRouter.distribute();
        assertEq(toReserve, 0.3 ether * 6_667 / 10_000);
        assertEq(toStakers, 0.3 ether - toReserve);
        assertEq(Terms.RESERVE.balance - reserveBefore, toReserve);
        assertEq(Terms.STAKING.balance - stakingBefore, toStakers);
    }

    /// The fee router's keeper sells the vault's fee synth (through a kDESIGN/USDG v4 pool the helper
    /// seeds at the index price, then the v3 USDG/WETH 0.01% pool) and some USDG through the
    /// adapter, at the quoted WETH, and distribute() pays the real Reserve and Staking. The pool's
    /// fee, spacing and range are test values: on mainnet they are the owner's decision.
    function _assertTheKeeperSellsTheFeesThroughTheAdapter() internal {
        (uint256 indexPrice,) = feeds[0].latestPrice();
        deal(Terms.USDG, helper, 400e6);
        Seed.Plan memory p = Seed.plan(
            address(synths[0]),
            Terms.USDG,
            indexPrice,
            4e18,
            400e6,
            Seed.Settings({fee: 3000, tickSpacing: 60, rangeBps: 0})
        );
        vm.startPrank(helper);
        Seed.seed(p, helper, block.timestamp + 30 minutes);
        vm.stopPrank();

        uint256 synthFees = synths[0].balanceOf(address(feeRouter));
        assertGt(synthFees, 0, "the mint and borrow fees, minted to the router");
        (uint256 usdgQuoted,) = IV4Quoter(RH.UNISWAP_V4_QUOTER)
            .quoteExactInputSingle(QuoteExactSingleParams(p.key, p.synthIsCurrency0, uint128(synthFees), ""));
        uint256 wethQuoted = _quoteUsdgForWeth(usdgQuoted);
        vm.prank(Terms.KEEPER);
        uint256 fromSynth = feeRouter.convert(
            address(synths[0]),
            address(swapAdapter),
            abi.encodeCall(SiliconSwapAdapter.sellSynth, (p.key, synthFees, V3_USDG_WETH_FEE)),
            synthFees,
            wethQuoted
        );
        assertEq(fromSynth, wethQuoted, "the quoted WETH for the fee synth");
        assertEq(synths[0].balanceOf(address(feeRouter)), 0);

        deal(Terms.USDG, address(feeRouter), 100e6);
        wethQuoted = _quoteUsdgForWeth(100e6);
        vm.prank(Terms.KEEPER);
        uint256 fromUsdg = feeRouter.convert(
            Terms.USDG,
            address(swapAdapter),
            abi.encodeCall(SiliconSwapAdapter.sellUsdg, (100e6, V3_USDG_WETH_FEE)),
            100e6,
            wethQuoted
        );
        assertEq(fromUsdg, wethQuoted, "the quoted WETH for the USDG");
        assertEq(IERC20(Terms.USDG).balanceOf(address(swapAdapter)), 0, "nothing left in the adapter");
        assertEq(synths[0].balanceOf(address(swapAdapter)), 0, "nothing left in the adapter");
        emit log_named_decimal_uint("fee synth sold (kDESIGN)", synthFees, 18);
        emit log_named_decimal_uint("  for WETH", fromSynth, 18);
        emit log_named_decimal_uint("100 USDG for WETH", fromUsdg, 18);

        uint256 reserveBefore = Terms.RESERVE.balance;
        uint256 stakingBefore = Terms.STAKING.balance;
        (uint256 toReserve, uint256 toStakers) = feeRouter.distribute();
        assertEq(toReserve + toStakers, fromSynth + fromUsdg);
        assertEq(Terms.RESERVE.balance - reserveBefore, toReserve);
        assertEq(Terms.STAKING.balance - stakingBefore, toStakers);
    }

    function _quoteUsdgForWeth(uint256 amountIn) internal returns (uint256 wethOut) {
        (wethOut,,,) = ISiliconQuoterV2(RH.UNISWAP_V3_QUOTER_V2)
            .quoteExactInputSingle(
                ISiliconQuoterV2.QuoteExactInputSingleParams(Terms.USDG, RH.WETH, amountIn, V3_USDG_WETH_FEE, 0)
            );
    }

    /// Once a market is open, a change to a vault-wide risk setting waits 24 hours in public, and
    /// the guardian (the owner wallet) can cancel it.
    function _assertRiskSettingsNowWait() internal {
        uint16 floorSetting = vault.SETTING_AUCTION_FLOOR();
        vm.prank(OWNER);
        vault.setAuctionFloor(8_000);
        assertEq(vault.auctionFloorBps(), 7_600, "still in force");
        (uint256 value, uint256 effectiveAt) = vault.pendingSettings(floorSetting, 0);
        assertEq(value, 8_000);
        assertEq(effectiveAt, block.timestamp + 24 hours);
        vm.prank(OWNER);
        vault.cancelSetting(floorSetting, 0);
        (, effectiveAt) = vault.pendingSettings(floorSetting, 0);
        assertEq(effectiveAt, 0);
    }

    /// The owner's liquidity, the deployment accepted, 24 hours of observations, the four markets
    /// open, and the clock at Monday 15:00 UTC.
    function _launchAndOpenInTheWindow() internal {
        _addLiquidity();
        _deploy();
        _acceptAll();
        _advance(block.timestamp + 1 days);
        _openAll();
        _advance(_mondayWindow(block.timestamp));
    }

    /// The largest mint for a first position at a 1:1 debt rate that leaves it at or above 150%:
    /// debt value (rounded up) at most collateral value / 1.5, the mint fee rounded up.
    function _largestMint(uint256 kyznAmount, uint256 usdgAmount, uint256 kyznUsd, uint256 synthUsd)
        internal
        pure
        returns (uint256 amount)
    {
        uint256 collateralValue = Math.mulDiv(kyznAmount, kyznUsd, 1e18) + usdgAmount * 1e12;
        uint256 maxDebtValue = collateralValue * 10_000 / 15_000;
        uint256 maxDebt = Math.mulDiv(maxDebtValue, 1e18, synthUsd);
        amount = maxDebt * 10_000 / 10_050;
        while (_withFee(amount + 1) <= maxDebt) ++amount;
        while (_withFee(amount) > maxDebt) --amount;
    }

    function _withFee(uint256 amount) internal pure returns (uint256) {
        return amount + Math.mulDiv(amount, Terms.MINT_FEE_BPS, 10_000, Math.Rounding.Ceil);
    }

    /// The auction is closed and every unit of the borrower's collateral is back: what its bid
    /// took and what returned to its position.
    function _assertCollateralBack(uint256 auctionId, uint256 kyznOut, uint256 usdgOut) internal view {
        assertEq(vault.auction(auctionId).account, address(0), "closed");
        (uint256 kyznBack, uint256 usdgBack, uint256 shares) = vault.positions(0, borrower);
        assertEq(shares, 0, "no debt");
        assertEq(kyznOut + kyznBack, borrowerKyzn, "every $KYZN");
        assertEq(usdgOut + usdgBack, borrowerUsdg, "every USDG");
    }

    function _poolKyzn() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = POOL.getReserves();
        return POOL.token0() == Terms.KYZN ? r0 : r1;
    }
}
