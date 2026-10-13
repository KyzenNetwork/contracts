// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Staking} from "../src/Staking.sol";
import {KyznUsdOracle} from "../src/silicon/KyznUsdOracle.sol";
import {SiliconFeeRouter} from "../src/silicon/SiliconFeeRouter.sol";
import {SiliconSwapAdapter} from "../src/silicon/SiliconSwapAdapter.sol";
import {SiliconVault} from "../src/silicon/SiliconVault.sol";
import {StockIndexFeed} from "../src/silicon/StockIndexFeed.sol";
import {SiliconMainnetTerms as Terms} from "./SiliconMainnet.sol";
import {RobinhoodChain as RH} from "./RobinhoodChain.sol";

/// The $KYZN/WETH pair's reserves, as far as the check reads them.
interface IOpenCheckPair {
    function getReserves() external view returns (uint112, uint112, uint32);
}

/// Whether the recorded Silicon mainnet deployment is ready for the owner's next transactions, and
/// those transactions. It sends nothing: every one is the owner wallet's, from the launch console.
///   - acceptOwnership on each contract the deployment offered (calendar, vault, fee router, the
///     four feeds), until the owner wallet owns all seven;
///   - Staking.setFeeSource(fee router), so that Staking takes the stakers' share (Staking takes
///     ETH only from the token and its one fee source);
///   - SiliconVault.openMarket(id) for each market, once (SPEC 3.5) the oracle has 24 hours of
///     observations, so that it prices $KYZN, and the pool has depth: each market's debt ceiling,
///     in USD at its index price now, at most the pool's $KYZN side in USD at the oracle's price
///     (SPEC 3.5: a ceiling never above the pool's USD depth). A market whose ceiling is above it
///     is reported, not listed: the owner lowers the ceiling (setDebtCeiling, at once) or waits.
///     Beside it the check prints the ceilings of the markets open and listed to open, summed,
///     next to the same depth: whether SPEC's limit is per market or for all of them together is
///     the owner's decision, and the check refuses only per market.
/// It lists no transaction at all unless every index prices above zero and is fresh enough to
/// liquidate on (isFreshForLiquidation). The methodology texts cannot be fetched from here: it
/// prints each feed's URL and hash for a check by hand. It also checks the recorded swap adapter:
/// its WETH is the fee router's, its USDG the vault's, its PoolManager and SwapRouter02 Robinhood
/// Chain's (it stops otherwise), and whether the fee router takes it as a target yet.
///
///   forge script script/SiliconMainnetOpen.s.sol --rpc-url robinhood
contract SiliconMainnetOpen is Script {
    string internal constant DEFAULT_FILE = "deployments/4663.json";
    uint256 internal constant MARKETS = 4;

    struct Status {
        /// The owner wallet owns the calendar, the vault, the fee router and the four feeds.
        bool accepted;
        /// Staking names the vault's fee router as its fee source.
        bool feeSource;
        /// Every index prices above zero and is fresh enough to liquidate on.
        bool indicesLive;
        /// The oracle prices $KYZN (it has its long window of observations, ETH/USD is fresh).
        bool priced;
        uint256 kyznUsd;
        uint256 observations;
        /// The pool's $KYZN side in USD at the oracle's price (0 until it prices).
        uint256 depthUsd;
        /// The debt ceilings, in USD at each index price now, of the markets open and of those
        /// that may open now, summed.
        uint256 totalCeilingUsd;
        bool[4] open;
        /// Every setting set and the feed ready (unsetSettings is 0).
        bool[4] settingsSet;
        /// The index price now (USD, 18 decimals) and whether it is fresh enough to liquidate on.
        uint256[4] indexPrice;
        bool[4] freshForLiquidation;
        /// The market's debt ceiling in USD at its index price now.
        uint256[4] ceilingUsd;
    }

    error NotMainnet(uint256 chainId);
    /// The swap adapter does not trade the fee router's WETH, the vault's USDG, or on the given
    /// PoolManager and SwapRouter02.
    error AdapterMismatch(address adapter);

    function run() external view {
        if (block.chainid != RH.CHAIN_ID) revert NotMainnet(block.chainid);
        string memory json = vm.readFile(vm.envOr("KYZEN_DEPLOYMENT_FILE", DEFAULT_FILE));
        SiliconVault vault = SiliconVault(vm.parseJsonAddress(json, ".silicon.vault"));
        SiliconSwapAdapter adapter = SiliconSwapAdapter(vm.parseJsonAddress(json, ".silicon.swapAdapter"));
        bool live = adapterStatus(adapter, vault, RH.UNISWAP_V4_POOL_MANAGER, RH.UNISWAP_V3_SWAP_ROUTER_02);
        console2.log("Swap adapter", address(adapter));
        console2.log("  WETH, USDG, PoolManager and SwapRouter02 as expected: true");
        console2.log("  the fee router's swap target now:", live);
        report(vault, Terms.OWNER);
    }

    /// Reverts AdapterMismatch unless `adapter` trades the fee router's WETH and the vault's USDG on
    /// `poolManager` and `swapRouter`; returns whether the fee router takes it as a target now.
    function adapterStatus(SiliconSwapAdapter adapter, SiliconVault vault, address poolManager, address swapRouter)
        public
        view
        returns (bool live)
    {
        SiliconFeeRouter router = SiliconFeeRouter(payable(vault.feeRouter()));
        if (
            adapter.weth() != address(router.weth()) || adapter.usdg() != address(vault.usdg())
                || address(adapter.poolManager()) != poolManager || address(adapter.swapRouter()) != swapRouter
        ) revert AdapterMismatch(address(adapter));
        live = router.isTargetAllowed(address(adapter));
    }

    /// The deployment's state, read from its vault, for `owner` (the owner wallet on mainnet). The
    /// pair, $KYZN and Staking are the ones the vault's oracle and fee router name.
    function status(SiliconVault vault, address owner) public view returns (Status memory s) {
        address[7] memory owned = _owned(vault);
        s.accepted = true;
        for (uint256 i; i < owned.length; ++i) {
            if (Ownable(owned[i]).owner() != owner) s.accepted = false;
        }
        SiliconFeeRouter router = SiliconFeeRouter(payable(vault.feeRouter()));
        s.feeSource = Staking(payable(router.staking())).feeSource() == address(router);

        KyznUsdOracle oracle = KyznUsdOracle(address(vault.oracle()));
        s.observations = oracle.observationCount();
        try oracle.price() returns (uint256 p) {
            s.priced = true;
            s.kyznUsd = p;
            s.depthUsd = Math.mulDiv(_poolKyzn(oracle), p, 1e18);
        } catch {}

        s.indicesLive = true;
        for (uint256 id; id < MARKETS; ++id) {
            SiliconVault.Market memory m = vault.market(id);
            s.open[id] = m.open;
            s.settingsSet[id] = vault.unsetSettings(id) == 0;
            (s.indexPrice[id],) = m.feed.latestPrice();
            s.freshForLiquidation[id] = m.feed.isFreshForLiquidation();
            if (s.indexPrice[id] == 0 || !s.freshForLiquidation[id]) s.indicesLive = false;
            s.ceilingUsd[id] = Math.mulDiv(m.debtCeiling, s.indexPrice[id], 1e18);
        }
        for (uint256 id; id < MARKETS; ++id) {
            if (s.open[id] || canOpen(s, id)) s.totalCeilingUsd += s.ceilingUsd[id];
        }
    }

    /// Whether market `id` may open now: every index live, the owner owns everything, the oracle
    /// prices $KYZN, every setting is set and the market's ceiling is within the pool's depth.
    function canOpen(Status memory s, uint256 id) public pure returns (bool) {
        return
            !s.open[id] && s.indicesLive && s.accepted && s.priced && s.settingsSet[id]
                && s.ceilingUsd[id] <= s.depthUsd;
    }

    /// Prints the state and the owner's transactions left (to, then data).
    function report(SiliconVault vault, address owner) public view {
        Status memory s = status(vault, owner);
        console2.log("Silicon vault", address(vault));
        console2.log("  owner wallet owns all seven contracts:", s.accepted);
        console2.log("  Staking's fee source is the fee router:", s.feeSource);
        console2.log("  oracle observations:", s.observations);
        console2.log("  oracle prices $KYZN:", s.priced);
        console2.log("  $KYZN in USD (1e18):", s.kyznUsd);
        console2.log("  pool depth, $KYZN side, USD (1e18):", s.depthUsd);
        console2.log("  ceilings of the markets open and opening, summed, USD (1e18):", s.totalCeilingUsd);
        console2.log("  (per market or in total: the owner decides; this check refuses per market)");
        for (uint256 id; id < MARKETS; ++id) {
            StockIndexFeed feed = StockIndexFeed(address(vault.market(id).feed));
            console2.log("  market", id);
            console2.log("    open:", s.open[id]);
            console2.log("    every setting set:", s.settingsSet[id]);
            console2.log("    index price, USD (1e18):", s.indexPrice[id]);
            console2.log("    fresh to liquidate on:", s.freshForLiquidation[id]);
            console2.log("    debt ceiling, USD (1e18):", s.ceilingUsd[id]);
            console2.log("    within the pool's depth:", s.ceilingUsd[id] <= s.depthUsd);
            console2.log("    methodology (check by hand that the URL serves bytes with this keccak-256):");
            console2.log("     ", feed.methodologyURI());
            console2.logBytes32(feed.methodologyHash());
        }

        if (!s.indicesLive) {
            console2.log("No transaction listed: an index prices at zero or is too old to liquidate on.");
            return;
        }
        console2.log("Owner wallet transactions left (to, then data):");
        address[7] memory owned = _owned(vault);
        for (uint256 i; i < owned.length; ++i) {
            if (Ownable(owned[i]).owner() == owner) continue;
            console2.log("  acceptOwnership()", owned[i]);
            console2.logBytes(abi.encodeWithSignature("acceptOwnership()"));
        }
        if (!s.feeSource) {
            address router = vault.feeRouter();
            console2.log("  Staking.setFeeSource(fee router)", SiliconFeeRouter(payable(router)).staking());
            console2.logBytes(abi.encodeCall(Staking.setFeeSource, (router)));
        }
        for (uint256 id; id < MARKETS; ++id) {
            if (s.open[id]) continue;
            if (canOpen(s, id)) {
                console2.log("  SiliconVault.openMarket", id, address(vault));
                console2.logBytes(abi.encodeCall(SiliconVault.openMarket, (id)));
            } else {
                console2.log("  not yet: openMarket", id);
            }
        }
    }

    function _owned(SiliconVault vault) private view returns (address[7] memory list) {
        list[0] = address(StockIndexFeed(address(vault.market(0).feed)).calendar());
        list[1] = address(vault);
        list[2] = vault.feeRouter();
        for (uint256 id; id < MARKETS; ++id) {
            list[3 + id] = address(vault.market(id).feed);
        }
    }

    function _poolKyzn(KyznUsdOracle oracle) private view returns (uint256) {
        (uint112 r0, uint112 r1,) = IOpenCheckPair(address(oracle.pair())).getReserves();
        return oracle.kyznIsToken0() ? r0 : r1;
    }
}
