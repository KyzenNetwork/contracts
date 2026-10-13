// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {KyznUsdOracle} from "../../src/silicon/KyznUsdOracle.sol";
import {MarketCalendar} from "../../src/silicon/MarketCalendar.sol";
import {SiliconFeeRouter} from "../../src/silicon/SiliconFeeRouter.sol";
import {SiliconSynth} from "../../src/silicon/SiliconSynth.sol";
import {SiliconVault} from "../../src/silicon/SiliconVault.sol";
import {StockIndexFeed} from "../../src/silicon/StockIndexFeed.sol";
import {IKyznUsdOracle} from "../../src/silicon/interfaces/IKyznUsdOracle.sol";
import {IMarketCalendar} from "../../src/silicon/interfaces/IMarketCalendar.sol";
import {ISiliconFeed} from "../../src/silicon/interfaces/ISiliconFeed.sol";
import {ISiliconSynth} from "../../src/silicon/interfaces/ISiliconSynth.sol";
import {IUniswapV2PairTwap} from "../../src/silicon/interfaces/IUniswapV2PairTwap.sol";
import {TestnetFeed} from "./TestnetFeed.sol";
import {TestnetUsdg} from "./TestnetUsdg.sol";
import {TestnetScript} from "./TestnetScript.sol";

/// The four Silicon stock indices on Robinhood Chain testnet (46630), or on an anvil fork of it
/// (31337), on top of the stack DeployTestnet wrote to deployments/<chainId>.json. The testnet has
/// no Chainlink feeds for the seven stocks and no USDG, so this script:
///   1. deploys seven owner-set feeds (TestnetFeed) for NVDA, AMD, MU, SNDK, TSM, INTC and ASML,
///      priced from the mainnet Chainlink feeds on the day, and a USDG stand-in (TestnetUsdg);
///   2. deploys the MarketCalendar and marks every exchange holiday and early close in
///      script/market-calendar.json;
///   3. deploys the $KYZN oracle on the testnet $KYZN/WETH pair and ETH/USD feed, with testnet
///      windows of 5 and 30 minutes (mainnet: 1 hour and 24 hours);
///   4. deploys the vault ($KYZN and the USDG stand-in as collateral), the fee router (two thirds
///      to the Reserve, the rest to Staking, the deployer as keeper), and per index a synth and a
///      StockIndexFeed on the stand-ins, with the deployer as guardian and the published
///      methodology;
///   5. adds the four markets and sets every level (SPEC 3.5), the auction duration at a testnet
///      10 minutes (mainnet: 100 minutes), the debt ceiling and minimum debt in synth at the
///      index's opening price, and names the deployer the vault's guardian (testnet only: on
///      mainnet the owner is the vault's guardian);
///   6. writes the addresses, the block it ran at (deployBlock) and the testnet-only parameters
///      under "silicon" in deployments/<chainId>.json, leaving the other keys as they are.
/// Every setting is made here, while no market is open, so each takes effect at once (once a
/// market is open the vault queues the risk settings for 24 hours). It does not open the markets:
/// the oracle has no price until its long window has passed with observations at least every
/// short window. Then open() opens them.
///
/// It refuses to replace a "silicon" entry already in the deployment file unless
/// KYZEN_SILICON_REDEPLOY is 1: a redeploy leaves the earlier contracts on chain and unrecorded.
///
/// It leaves Staking's fee source alone, so the fee router's distribute() reverts on testnet
/// (Staking takes ETH only from its fee source): fee distribution is not part of the testnet
/// drills.
///
/// Each index's methodology is its published text, docs.kyzen.network/methodology/<slug>.txt, and
/// its hash the keccak-256 of that text as methodology-hashes.json records it,
/// as on mainnet.
///
/// The deployer is the `--private-key` (or `--sender`) address and must be the deployer recorded
/// by DeployTestnet: it owns every contract and feed here, is the indices' and the vault's
/// guardian and the fee router's keeper.
///
/// Environment:
///   KYZEN_SILICON_NVDA_USD, KYZEN_SILICON_AMD_USD, KYZEN_SILICON_MU_USD, KYZEN_SILICON_SNDK_USD,
///   KYZEN_SILICON_TSM_USD, KYZEN_SILICON_INTC_USD, KYZEN_SILICON_ASML_USD
///       the mainnet Chainlink answers on the day (8 decimals)
///   KYZEN_SILICON_REDEPLOY   1 to replace a "silicon" entry already recorded (optional)
contract DeploySilicon is TestnetScript {
    /// The stocks of the four baskets, in the order of their stand-in feeds.
    uint256 private constant STOCKS = 7;
    uint256 private constant NVDA = 0;
    uint256 private constant AMD = 1;
    uint256 private constant MU = 2;
    uint256 private constant SNDK = 3;
    uint256 private constant TSM = 4;
    uint256 private constant INTC = 5;
    uint256 private constant ASML = 6;
    uint256 private constant MARKETS = 4;

    /// The oracle's windows: testnet only (mainnet: 1 hour and 24 hours).
    uint256 internal constant ORACLE_SHORT_WINDOW = 5 minutes;
    uint256 internal constant ORACLE_LONG_WINDOW = 30 minutes;
    /// The levels of SPEC 3.5, per market.
    uint256 internal constant MINT_FEE_BPS = 50; // 0.5% of each mint
    uint256 internal constant BORROW_FEE_BPS_PER_YEAR = 1_200; // 12% a year
    uint256 internal constant LIQUIDATION_PENALTY_BPS = 1_300; // 13%
    uint256 internal constant DEBT_CEILING_USD = 25_000e18; // of synth at the opening price
    uint256 internal constant MIN_DEBT_USD = 500e18; // of synth at the opening price
    /// Vault-wide: the auction duration is testnet only (mainnet: 100 minutes).
    uint256 internal constant AUCTION_DURATION = 10 minutes;
    uint256 internal constant AUCTION_START_PREMIUM_BPS = 2_000; // 20% above the oracle value
    uint256 internal constant AUCTION_FLOOR_BPS = 7_600; // never below 76% of it
    /// Two thirds of the fees to the Reserve, one third to the stakers.
    uint256 internal constant RESERVE_SHARE_BPS = 6_667;

    /// The exchange calendar, generated by scripts/market-calendar.mjs.
    string internal constant CALENDAR_FILE = "script/market-calendar.json";
    /// Where each index's methodology text is published: <base><slug>.txt.
    string internal constant METHODOLOGY_BASE = "https://docs.kyzen.network/methodology/";
    /// The keccak-256 of each published methodology text, by slug.
    string internal constant METHODOLOGY_HASHES = "./methodology-hashes.json";

    /// One index: its names, its methodology page and the stocks of its basket.
    struct Index {
        string name; // "Design", as the deployment file records it
        string symbol;
        string slug; // the methodology text
        uint256[] stocks;
        bytes32 methodologyHash;
    }

    /// One market as deployed.
    struct Market {
        SiliconSynth synth;
        StockIndexFeed feed;
        uint256 openingPrice;
        uint256 debtCeiling;
        uint256 minDebt;
    }

    /// Everything this script deploys.
    struct Silicon {
        address deployer;
        uint256 deployBlock;
        TestnetFeed[] stockFeeds;
        TestnetUsdg usdg;
        MarketCalendar calendar;
        KyznUsdOracle oracle;
        SiliconVault vault;
        SiliconFeeRouter feeRouter;
        Market[] markets;
    }

    error BadPrice(string name);
    error NotDeployer(address sender, address deployer);
    error NotVaultOwner(address sender, address owner);
    error EmptyCalendar();
    error MarketMismatch(uint256 id);
    error OracleMismatch(address vaultOracle, address recorded);
    error MarketCountMismatch(uint256 count);
    error MarketNotReady(uint256 id, uint16 unset);
    error ZeroOpeningPrice(uint256 id);
    error SiliconAlreadyRecorded(string path);
    error NoMethodologyHash(string slug);
    error SettingMismatch(string setting);

    // ---------------------------------------------------------------- entry points

    /// Deploys and configures everything, markets closed, and records it.
    function run() external {
        Addresses memory a = _load(); // checks the chain
        if (msg.sender != a.deployer) revert NotDeployer(msg.sender, a.deployer);
        _checkNotRecorded();
        int256[] memory prices = _prices();
        (uint256[] memory closed, uint256[] memory early) = _calendarDays();
        Index[] memory indices = _indices();

        Silicon memory s;
        s.deployer = a.deployer;
        s.deployBlock = block.number;
        s.stockFeeds = new TestnetFeed[](STOCKS);
        s.markets = new Market[](MARKETS);

        vm.startBroadcast(s.deployer);
        _deployCore(s, a, prices, closed, early);
        for (uint256 i = 0; i < MARKETS; ++i) {
            _deployMarket(s, i, indices[i]);
        }
        s.vault.setAuctionDuration(AUCTION_DURATION);
        s.vault.setAuctionStartPremium(AUCTION_START_PREMIUM_BPS);
        s.vault.setAuctionFloor(AUCTION_FLOOR_BPS);
        s.vault.setFeeRouter(address(s.feeRouter));
        s.vault.setGuardian(s.deployer);
        vm.stopBroadcast();

        for (uint256 id = 0; id < MARKETS; ++id) {
            uint16 unset = s.vault.unsetSettings(id);
            if (unset != 0) revert MarketNotReady(id, unset);
        }
        if (s.vault.auctionFloorBps() != AUCTION_FLOOR_BPS) revert SettingMismatch("auction floor");
        if (s.vault.guardian() != s.deployer) revert SettingMismatch("guardian");
        _log(s, indices, closed.length, early.length);
        _write(s, indices);
    }

    /// Opens the four markets recorded under "silicon", once the oracle has a price: one long
    /// window after the oracle's deployment, with observations at most two short windows apart.
    /// Checks each market against the deployment file and that every setting is set first. A
    /// market already open is left as it is, so a second run after a partial one finishes the job.
    function open() external {
        _load(); // checks the chain
        // Reads only deployments/, which foundry.toml's fs_permissions allow.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(_deploymentPath());
        SiliconVault vault = SiliconVault(vm.parseJsonAddress(json, ".silicon.vault"));
        KyznUsdOracle oracle = KyznUsdOracle(vm.parseJsonAddress(json, ".silicon.oracle"));
        if (address(vault.oracle()) != address(oracle)) {
            revert OracleMismatch(address(vault.oracle()), address(oracle));
        }
        if (msg.sender != vault.owner()) revert NotVaultOwner(msg.sender, vault.owner());
        uint256 kyznUsd = oracle.price(); // reverts until the oracle has a price
        console2.log("$KYZN/USD (1e18)         ", kyznUsd);

        uint256 count = vault.marketCount();
        if (count != MARKETS) revert MarketCountMismatch(count);
        bool[] memory toOpen = new bool[](count);
        for (uint256 id = 0; id < count; ++id) {
            string memory path = string.concat(".silicon.markets[", vm.toString(id), "]");
            SiliconVault.Market memory m = vault.market(id);
            if (
                address(m.synth) != vm.parseJsonAddress(json, string.concat(path, ".synth"))
                    || address(m.feed) != vm.parseJsonAddress(json, string.concat(path, ".feed"))
            ) revert MarketMismatch(id);
            uint16 unset = vault.unsetSettings(id);
            if (unset != 0) revert MarketNotReady(id, unset);
            toOpen[id] = !m.open;
            if (m.open) console2.log("Already open             ", id);
            else console2.log("Opening                  ", id);
        }

        vm.startBroadcast(msg.sender);
        for (uint256 id = 0; id < count; ++id) {
            if (toOpen[id]) vault.openMarket(id);
        }
        vm.stopBroadcast();
    }

    // ---------------------------------------------------------------- deployment

    /// The stand-ins, the calendar, the oracle, the vault and the fee router.
    function _deployCore(
        Silicon memory s,
        Addresses memory a,
        int256[] memory prices,
        uint256[] memory closed,
        uint256[] memory early
    ) private {
        string[] memory tickers = _tickers();
        for (uint256 i = 0; i < STOCKS; ++i) {
            s.stockFeeds[i] = new TestnetFeed(string.concat(tickers[i], " / USD testnet stand-in"), prices[i]);
        }
        s.usdg = new TestnetUsdg();

        s.calendar = new MarketCalendar(s.deployer);
        s.calendar.setDays(closed, MarketCalendar.DayKind.Closed);
        s.calendar.setDays(early, MarketCalendar.DayKind.EarlyClose);

        s.oracle = new KyznUsdOracle(
            IUniswapV2PairTwap(a.pair), a.token, a.ethUsdFeed, ORACLE_SHORT_WINDOW, ORACLE_LONG_WINDOW
        );
        s.vault = new SiliconVault(IERC20(a.token), IERC20(address(s.usdg)), IKyznUsdOracle(address(s.oracle)));

        s.feeRouter = new SiliconFeeRouter(IWETH(WETH));
        s.feeRouter.setReserve(a.reserve);
        s.feeRouter.setStaking(a.staking);
        s.feeRouter.setSplit(RESERVE_SHARE_BPS);
        s.feeRouter.setKeeper(s.deployer);
    }

    /// Market `i`: its synth and index feed, added to the vault with every per-market level.
    function _deployMarket(Silicon memory s, uint256 i, Index memory index) private {
        Market memory m = s.markets[i];
        m.synth =
            new SiliconSynth(string.concat("Kyzen Network ", index.name, " index"), index.symbol, address(s.vault));

        address[] memory feeds = new address[](index.stocks.length);
        for (uint256 j = 0; j < feeds.length; ++j) {
            feeds[j] = address(s.stockFeeds[index.stocks[j]]);
        }
        m.feed = new StockIndexFeed(
            string.concat("Kyzen Network ", index.name, " index / USD"),
            IMarketCalendar(address(s.calendar)),
            feeds,
            s.deployer
        );
        m.feed.setGuardian(s.deployer);
        m.feed.setMethodology(string.concat(METHODOLOGY_BASE, index.slug, ".txt"), index.methodologyHash);

        uint256 id = s.vault.addMarket(ISiliconSynth(address(m.synth)), ISiliconFeed(address(m.feed)));
        if (id != i) revert MarketMismatch(id);
        (m.openingPrice,) = m.feed.latestPrice();
        if (m.openingPrice == 0) revert ZeroOpeningPrice(id);
        // Synth units (18 decimals) worth the USD amount at the opening price: the ceiling rounded
        // down, the minimum rounded up, so neither is ever worth more (ceiling) or less (minimum).
        m.debtCeiling = Math.mulDiv(DEBT_CEILING_USD, 1e18, m.openingPrice);
        m.minDebt = Math.mulDiv(MIN_DEBT_USD, 1e18, m.openingPrice, Math.Rounding.Ceil);

        s.vault.setMintFee(id, MINT_FEE_BPS);
        s.vault.setBorrowFee(id, BORROW_FEE_BPS_PER_YEAR);
        s.vault.setLiquidationPenalty(id, LIQUIDATION_PENALTY_BPS);
        s.vault.setDebtCeiling(id, m.debtCeiling);
        s.vault.setMinDebt(id, m.minDebt);
    }

    // ---------------------------------------------------------------- inputs

    function _tickers() private pure returns (string[] memory t) {
        t = new string[](STOCKS);
        t[NVDA] = "NVDA";
        t[AMD] = "AMD";
        t[MU] = "MU";
        t[SNDK] = "SNDK";
        t[TSM] = "TSM";
        t[INTC] = "INTC";
        t[ASML] = "ASML";
    }

    /// The four indices: Design (NVDA, AMD), Memory (MU, SNDK), Fab (TSM, INTC), Equipment (ASML),
    /// each with the hash of its published methodology text.
    function _indices() private view returns (Index[] memory x) {
        x = new Index[](MARKETS);
        x[0] = Index({name: "Design", symbol: "kDESIGN", slug: "kdesign", stocks: _pair(NVDA, AMD), methodologyHash: 0});
        x[1] = Index({name: "Memory", symbol: "kMEMORY", slug: "kmemory", stocks: _pair(MU, SNDK), methodologyHash: 0});
        x[2] = Index({name: "Fab", symbol: "kFAB", slug: "kfab", stocks: _pair(TSM, INTC), methodologyHash: 0});
        uint256[] memory equipment = new uint256[](1);
        equipment[0] = ASML;
        x[3] = Index({name: "Equipment", symbol: "kEQUIP", slug: "kequip", stocks: equipment, methodologyHash: 0});
        // Reads one file the docs build writes, which foundry.toml's fs_permissions allow.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(METHODOLOGY_HASHES);
        for (uint256 i = 0; i < MARKETS; ++i) {
            x[i].methodologyHash = vm.parseJsonBytes32(json, string.concat(".", x[i].slug, ".keccak256"));
            if (x[i].methodologyHash == bytes32(0)) revert NoMethodologyHash(x[i].slug);
        }
    }

    /// Reverts when the deployment file already records "silicon", unless KYZEN_SILICON_REDEPLOY
    /// is 1.
    function _checkNotRecorded() private view {
        // Reads only deployments/, which foundry.toml's fs_permissions allow.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(_deploymentPath());
        if (vm.keyExistsJson(json, ".silicon") && vm.envOr("KYZEN_SILICON_REDEPLOY", uint256(0)) != 1) {
            revert SiliconAlreadyRecorded(_deploymentPath());
        }
    }

    function _pair(uint256 first, uint256 second) private pure returns (uint256[] memory p) {
        p = new uint256[](2);
        p[0] = first;
        p[1] = second;
    }

    /// The seven stocks' mainnet Chainlink answers on the day (8 decimals), from the environment.
    function _prices() private view returns (int256[] memory p) {
        string[] memory tickers = _tickers();
        p = new int256[](STOCKS);
        for (uint256 i = 0; i < STOCKS; ++i) {
            string memory name = string.concat("KYZEN_SILICON_", tickers[i], "_USD");
            p[i] = vm.envInt(name);
            if (p[i] <= 0) revert BadPrice(name);
        }
    }

    /// The closed and early-close UTC day numbers of the exchange calendar.
    function _calendarDays() private view returns (uint256[] memory closed, uint256[] memory early) {
        // Reads only script/, which foundry.toml's fs_permissions allow.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(CALENDAR_FILE);
        closed = abi.decode(vm.parseJson(json, ".closed[*].day"), (uint256[]));
        early = abi.decode(vm.parseJson(json, ".earlyClose[*].day"), (uint256[]));
        if (closed.length == 0 || early.length == 0) revert EmptyCalendar();
    }

    // ---------------------------------------------------------------- output

    /// Writes "silicon" into deployments/<chainId>.json; the other keys stay as they are. The
    /// debt ceiling and minimum debt are decimal strings (synth units, 18 decimals), since they
    /// pass JavaScript's safe integers.
    function _write(Silicon memory s, Index[] memory indices) private {
        string[] memory tickers = _tickers();
        string memory feedsJson;
        for (uint256 i = 0; i < STOCKS; ++i) {
            feedsJson = vm.serializeAddress("siliconStockFeeds", tickers[i], address(s.stockFeeds[i]));
        }
        string[] memory marketsJson = new string[](MARKETS);
        for (uint256 i = 0; i < MARKETS; ++i) {
            string memory k = string.concat("siliconMarket", vm.toString(i));
            Market memory m = s.markets[i];
            vm.serializeString(k, "name", indices[i].name);
            vm.serializeString(k, "symbol", indices[i].symbol);
            vm.serializeAddress(k, "synth", address(m.synth));
            vm.serializeAddress(k, "feed", address(m.feed));
            vm.serializeString(k, "debtCeiling", vm.toString(m.debtCeiling));
            marketsJson[i] = vm.serializeString(k, "minDebt", vm.toString(m.minDebt));
        }
        string memory k2 = "silicon";
        vm.serializeAddress(k2, "vault", address(s.vault));
        vm.serializeAddress(k2, "feeRouter", address(s.feeRouter));
        vm.serializeAddress(k2, "oracle", address(s.oracle));
        vm.serializeAddress(k2, "calendar", address(s.calendar));
        vm.serializeAddress(k2, "usdg", address(s.usdg));
        vm.serializeUint(k2, "deployBlock", s.deployBlock);
        vm.serializeUint(k2, "oracleShortWindow", ORACLE_SHORT_WINDOW);
        vm.serializeUint(k2, "oracleLongWindow", ORACLE_LONG_WINDOW);
        vm.serializeUint(k2, "auctionDuration", AUCTION_DURATION);
        vm.serializeString(k2, "stockFeeds", feedsJson);
        string memory json = vm.serializeString(k2, "markets", marketsJson);
        vm.writeJson(json, _deploymentPath(), ".silicon");
    }

    function _log(Silicon memory s, Index[] memory indices, uint256 closedDays, uint256 earlyDays) private view {
        string[] memory tickers = _tickers();
        console2.log("Chain id                 ", block.chainid);
        console2.log("Deployer (owner)         ", s.deployer);
        console2.log("Deploy block             ", s.deployBlock);
        for (uint256 i = 0; i < STOCKS; ++i) {
            console2.log(string.concat(tickers[i], " / USD stand-in"), address(s.stockFeeds[i]));
        }
        console2.log("USDG stand-in            ", address(s.usdg));
        console2.log("MarketCalendar           ", address(s.calendar));
        console2.log("  closed days            ", closedDays);
        console2.log("  early closes           ", earlyDays);
        console2.log("KyznUsdOracle            ", address(s.oracle));
        console2.log("SiliconVault             ", address(s.vault));
        console2.log("  guardian               ", s.vault.guardian());
        console2.log("  auction floor (bps)    ", s.vault.auctionFloorBps());
        console2.log("SiliconFeeRouter         ", address(s.feeRouter));
        for (uint256 i = 0; i < MARKETS; ++i) {
            Market memory m = s.markets[i];
            console2.log(string.concat(indices[i].symbol, " synth"), address(m.synth));
            console2.log(string.concat(indices[i].symbol, " feed"), address(m.feed));
            console2.log("  methodology            ", m.feed.methodologyURI());
            console2.log("  methodology hash       ", vm.toString(m.feed.methodologyHash()));
            console2.log("  opening price (1e18)   ", m.openingPrice);
            console2.log("  debt ceiling           ", _units(m.debtCeiling));
            console2.log("  minimum debt           ", _units(m.minDebt));
        }
        console2.log("Written to               ", _deploymentPath());
    }
}
