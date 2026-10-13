// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {KyznUsdOracle} from "../src/silicon/KyznUsdOracle.sol";
import {SiliconFeeRouter} from "../src/silicon/SiliconFeeRouter.sol";
import {SiliconSwapAdapter} from "../src/silicon/SiliconSwapAdapter.sol";
import {SiliconSynth} from "../src/silicon/SiliconSynth.sol";
import {SiliconVault} from "../src/silicon/SiliconVault.sol";
import {StockIndexFeed} from "../src/silicon/StockIndexFeed.sol";
import {SiliconDeployment, SiliconMainnet, SiliconMainnetTerms as Terms} from "./SiliconMainnet.sol";
import {RobinhoodChain as RH} from "./RobinhoodChain.sol";

/// Records the Silicon stock indices' mainnet deployment, made from the owner's wallet where no
/// broadcast writes deployments/4663.json: one SiliconMainnet contract deployed from the launch
/// console. From that contract's address (its deployment transaction's contractAddress) it reads
/// every address on chain, checks that each one has code and points at the others, at $KYZN,
/// USDG, WETH, the pair, the Reserve, Staking, the keeper, the Chainlink feeds and Uniswap (the
/// swap adapter, the fee router's target, live or queued), and belongs to the owner wallet (owned,
/// or offered to it until it accepts), and writes the "silicon" object of deployments/4663.json
/// (the keys DeploySilicon writes for the testnet, with deployBlock, the chain's block number of
/// the deployment, where the worker starts reading the vault's logs, and swapAdapter). The other
/// keys of the file stay as they are. It sends nothing.
///
///   TX=0x<the deployment transaction>
///   export KYZEN_SILICON=$(cast receipt $TX contractAddress --rpc-url robinhood)
///   export KYZEN_SILICON_BLOCK=$(cast receipt $TX blockNumber --rpc-url robinhood)
///   forge script script/RecordSiliconMainnet.s.sol --rpc-url robinhood
///   cd .. && node scripts/sync-deployments.mjs
///
/// KYZEN_SILICON_BLOCK is required for deployments/4663.json: the run stops unless it is the block
/// the deployment recorded from ArbSys. KYZEN_DEPLOYMENT_FILE writes another file under
/// deployments/ instead (the fork test does), where the block is optional.
contract RecordSiliconMainnet is Script {
    string internal constant DEFAULT_FILE = "deployments/4663.json";
    uint256 internal constant MARKETS = 4;
    uint256 internal constant STOCKS = 7;

    /// One market, as deployments/<chainId>.json records it.
    struct Market {
        string name;
        string symbol;
        address synth;
        address feed;
        uint256 debtCeiling;
        uint256 minDebt;
    }

    /// Everything the record holds.
    struct Record {
        address deployment;
        uint256 deployBlock;
        address owner;
        address calendar;
        address oracle;
        address vault;
        address feeRouter;
        address swapAdapter;
        address usdg;
        uint256 oracleShortWindow;
        uint256 oracleLongWindow;
        uint256 auctionDuration;
        Market[4] markets;
    }

    error NotMainnet(uint256 chainId);
    error NoCode(string name, address account);
    error Mismatch(string what, address expected, address actual);
    error ValueMismatch(string what, uint256 expected, uint256 actual);
    error NameMismatch(string what, string expected, string actual);
    error HashMismatch(string what, bytes32 expected, bytes32 actual);
    /// A contract belongs to someone other than the owner wallet.
    error NotOwnedBy(string name, address expected, address actual);
    /// The swap adapter is neither the fee router's swap target nor queued to be.
    error NotATarget(address adapter);
    /// The mainnet file is written only with the deployment receipt's block (KYZEN_SILICON_BLOCK).
    error ReceiptBlockRequired(string file);

    function run() external {
        record(
            vm.envAddress("KYZEN_SILICON"),
            vm.envOr("KYZEN_SILICON_BLOCK", uint256(0)),
            vm.envOr("KYZEN_DEPLOYMENT_FILE", DEFAULT_FILE)
        );
    }

    /// Reads deployment `deployment`, checks that `receiptBlock` (the block of its transaction's
    /// receipt; 0 for none) is the block it recorded, and writes it into `file`. Writing the
    /// mainnet file (deployments/4663.json) needs the receipt's block.
    function record(address deployment, uint256 receiptBlock, string memory file) public {
        if (block.chainid != RH.CHAIN_ID) revert NotMainnet(block.chainid);
        if (receiptBlock == 0 && _isMainnetFile(file)) revert ReceiptBlockRequired(file);
        Record memory r = read(deployment);
        if (receiptBlock != 0 && receiptBlock != r.deployBlock) {
            revert ValueMismatch("deployBlock", receiptBlock, r.deployBlock);
        }
        write(r, file);
        _report(r, file);
    }

    /// Every address of the deployment, read from the SiliconMainnet contract and checked; reverts
    /// on the first one that is missing or points elsewhere.
    function read(address deploymentAddr) public view returns (Record memory r) {
        _code("SiliconMainnet", deploymentAddr);
        SiliconMainnet d = SiliconMainnet(deploymentAddr);
        r.deployment = deploymentAddr;
        r.owner = d.owner();
        _same("deployment.owner", Terms.OWNER, r.owner);
        r.deployBlock = d.deployBlock();
        r.calendar = address(d.calendar());
        r.oracle = address(d.oracle());
        r.vault = address(d.vault());
        r.feeRouter = address(d.feeRouter());
        r.swapAdapter = address(d.swapAdapter());
        _code("MarketCalendar", r.calendar);
        _code("KyznUsdOracle", r.oracle);
        _code("SiliconVault", r.vault);
        _code("SiliconFeeRouter", r.feeRouter);
        _code("SiliconSwapAdapter", r.swapAdapter);
        _ownedBy("MarketCalendar", r.calendar);
        _ownedBy("SiliconVault", r.vault);
        _ownedBy("SiliconFeeRouter", r.feeRouter);

        _readOracle(r);
        _readVault(r);
        _readFeeRouter(r);
        _readSwapAdapter(r);
        SiliconSynth[4] memory synths = d.synths();
        StockIndexFeed[4] memory feeds = d.feeds();
        for (uint256 i; i < MARKETS; ++i) {
            r.markets[i] = _readMarket(r, i, synths[i], feeds[i]);
        }
    }

    /// Writes the "silicon" object into `file` (relative to contracts/); the other keys stay. The
    /// debt ceiling and minimum debt are decimal strings (synth units, 18 decimals), since they
    /// pass JavaScript's safe integers.
    function write(Record memory r, string memory file) public {
        string[7] memory tickers = _tickers();
        address[7] memory stockFeeds = _stockFeeds();
        string memory feedsJson;
        for (uint256 i; i < STOCKS; ++i) {
            feedsJson = vm.serializeAddress("siliconMainnetStockFeeds", tickers[i], stockFeeds[i]);
        }
        string[] memory marketsJson = new string[](MARKETS);
        for (uint256 i; i < MARKETS; ++i) {
            string memory k = string.concat("siliconMainnetMarket", vm.toString(i));
            Market memory m = r.markets[i];
            vm.serializeString(k, "name", m.name);
            vm.serializeString(k, "symbol", m.symbol);
            vm.serializeAddress(k, "synth", m.synth);
            vm.serializeAddress(k, "feed", m.feed);
            vm.serializeString(k, "debtCeiling", vm.toString(m.debtCeiling));
            marketsJson[i] = vm.serializeString(k, "minDebt", vm.toString(m.minDebt));
        }
        string memory s = "siliconMainnet";
        vm.serializeAddress(s, "vault", r.vault);
        vm.serializeAddress(s, "feeRouter", r.feeRouter);
        vm.serializeAddress(s, "swapAdapter", r.swapAdapter);
        vm.serializeAddress(s, "oracle", r.oracle);
        vm.serializeAddress(s, "calendar", r.calendar);
        vm.serializeAddress(s, "usdg", r.usdg);
        vm.serializeUint(s, "oracleShortWindow", r.oracleShortWindow);
        vm.serializeUint(s, "oracleLongWindow", r.oracleLongWindow);
        vm.serializeUint(s, "auctionDuration", r.auctionDuration);
        vm.serializeUint(s, "deployBlock", r.deployBlock);
        vm.serializeString(s, "stockFeeds", feedsJson);
        string memory json = vm.serializeString(s, "markets", marketsJson);
        vm.writeJson(json, file, ".silicon");
    }

    // ---------------------------------------------------------------- reads

    function _readOracle(Record memory r) private view {
        KyznUsdOracle oracle = KyznUsdOracle(r.oracle);
        _same("oracle.pair", Terms.PAIR, address(oracle.pair()));
        _same("oracle.kyzn", Terms.KYZN, oracle.kyzn());
        _same("oracle.weth", RH.WETH, oracle.weth());
        _same("oracle.ethUsdFeed", RH.ETH_USD_FEED, oracle.ethUsdFeed());
        r.oracleShortWindow = oracle.shortWindow();
        r.oracleLongWindow = oracle.longWindow();
    }

    function _readVault(Record memory r) private view {
        SiliconVault vault = SiliconVault(r.vault);
        _same("vault.kyzn", Terms.KYZN, address(vault.kyzn()));
        r.usdg = address(vault.usdg());
        _same("vault.usdg", Terms.USDG, r.usdg);
        _same("vault.oracle", r.oracle, address(vault.oracle()));
        _same("vault.feeRouter", r.feeRouter, vault.feeRouter());
        _same("vault.guardian", Terms.OWNER, vault.guardian());
        _equal("vault.marketCount", MARKETS, vault.marketCount());
        r.auctionDuration = vault.auctionDuration();
    }

    function _readFeeRouter(Record memory r) private view {
        SiliconFeeRouter router = SiliconFeeRouter(payable(r.feeRouter));
        _same("feeRouter.weth", RH.WETH, address(router.weth()));
        _same("feeRouter.reserve", Terms.RESERVE, router.reserve());
        _same("feeRouter.staking", Terms.STAKING, router.staking());
        _same("feeRouter.keeper", Terms.KEEPER, router.keeper());
    }

    /// The adapter trades on Robinhood Chain's Uniswap v4 PoolManager and v3 SwapRouter02 for WETH
    /// and USDG, and is the fee router's swap target: live, or queued to be.
    function _readSwapAdapter(Record memory r) private view {
        SiliconSwapAdapter adapter = SiliconSwapAdapter(r.swapAdapter);
        _same("swapAdapter.poolManager", RH.UNISWAP_V4_POOL_MANAGER, address(adapter.poolManager()));
        _same("swapAdapter.swapRouter", RH.UNISWAP_V3_SWAP_ROUTER_02, address(adapter.swapRouter()));
        _same("swapAdapter.weth", RH.WETH, adapter.weth());
        _same("swapAdapter.usdg", Terms.USDG, adapter.usdg());
        SiliconFeeRouter router = SiliconFeeRouter(payable(r.feeRouter));
        // The WETH the router counts and unwraps, and the vault's USDG.
        _same("swapAdapter.weth", address(router.weth()), adapter.weth());
        _same("swapAdapter.usdg", address(SiliconVault(r.vault).usdg()), adapter.usdg());
        (bool queued,) = router.pendingTarget(r.swapAdapter);
        if (!router.isTargetAllowed(r.swapAdapter) && !queued) revert NotATarget(r.swapAdapter);
    }

    function _readMarket(Record memory r, uint256 id, SiliconSynth synth, StockIndexFeed feed)
        private
        view
        returns (Market memory m)
    {
        SiliconDeployment.Index memory x = Terms.index(id);
        (m.name, m.symbol) = (x.name, x.symbol);
        SiliconVault.Market memory market_ = SiliconVault(r.vault).market(id);
        _same("market.synth", address(synth), address(market_.synth));
        _same("market.feed", address(feed), address(market_.feed));
        _code("SiliconSynth", address(synth));
        _code("StockIndexFeed", address(feed));
        _same("synth.vault", r.vault, synth.vault());
        _name("synth.symbol", m.symbol, synth.symbol());
        _name("synth.name", string.concat("Kyzen Network ", m.name, " index"), synth.name());
        _same("feed.calendar", r.calendar, address(feed.calendar()));
        _same("feed.guardian", Terms.OWNER, feed.guardian());
        bytes32 hash = feed.methodologyHash();
        if (hash != x.methodologyHash) revert HashMismatch("feed.methodologyHash", x.methodologyHash, hash);
        _name("feed.methodologyURI", x.methodologyURI, feed.methodologyURI());
        _ownedBy(string.concat("StockIndexFeed ", m.symbol), address(feed));
        address[] memory basket = x.feeds;
        _equal("feed.componentCount", basket.length, feed.componentCount());
        for (uint256 j; j < basket.length; ++j) {
            (address component,,) = feed.component(j);
            _same("feed.component", basket[j], component);
        }
        m.synth = address(synth);
        m.feed = address(feed);
        m.debtCeiling = market_.debtCeiling;
        m.minDebt = market_.minDebt;
    }

    // ---------------------------------------------------------------- the deployment's terms

    function _tickers() private pure returns (string[7] memory) {
        return ["AMD", "ASML", "INTC", "MU", "NVDA", "SNDK", "TSM"];
    }

    function _stockFeeds() private pure returns (address[7] memory) {
        return [RH.AMD_USD, RH.ASML_USD, RH.INTC_USD, RH.MU_USD, RH.NVDA_USD, RH.SNDK_USD, RH.TSM_USD];
    }

    // ---------------------------------------------------------------- checks

    /// The contract's owner, or the owner it was offered to until it accepts, is the owner wallet.
    function _ownedBy(string memory name, address account) private view {
        Ownable2Step c = Ownable2Step(account);
        address pending = c.pendingOwner();
        address side = pending != address(0) ? pending : c.owner();
        if (side != Terms.OWNER) revert NotOwnedBy(name, Terms.OWNER, side);
    }

    /// Whether `file` is the mainnet deployment file: named 4663.json, in whatever directory.
    function _isMainnetFile(string memory file) private pure returns (bool) {
        bytes memory f = bytes(file);
        bytes memory name = bytes("4663.json");
        if (f.length < name.length) return false;
        uint256 start = f.length - name.length;
        for (uint256 i; i < name.length; ++i) {
            if (f[start + i] != name[i]) return false;
        }
        return start == 0 || f[start - 1] == "/";
    }

    function _code(string memory name, address account) private view {
        if (account.code.length == 0) revert NoCode(name, account);
    }

    function _same(string memory what, address expected, address actual) private pure {
        if (expected != actual) revert Mismatch(what, expected, actual);
    }

    function _equal(string memory what, uint256 expected, uint256 actual) private pure {
        if (expected != actual) revert ValueMismatch(what, expected, actual);
    }

    function _name(string memory what, string memory expected, string memory actual) private pure {
        if (keccak256(bytes(expected)) != keccak256(bytes(actual))) revert NameMismatch(what, expected, actual);
    }

    // ---------------------------------------------------------------- report

    function _report(Record memory r, string memory file) private view {
        console2.log("Recorded", file);
        console2.log("  SiliconMainnet      ", r.deployment);
        console2.log("  deploy block        ", r.deployBlock);
        console2.log("  vault               ", r.vault);
        console2.log("  oracle              ", r.oracle);
        console2.log("  calendar            ", r.calendar);
        console2.log("  fee router          ", r.feeRouter);
        console2.log("  swap adapter        ", r.swapAdapter);
        for (uint256 i; i < MARKETS; ++i) {
            console2.log(
                string.concat("  ", r.markets[i].symbol, " synth / feed"), r.markets[i].synth, r.markets[i].feed
            );
        }
        _owner("  vault owner         ", r.vault);
        _owner("  calendar owner      ", r.calendar);
        _owner("  fee router owner    ", r.feeRouter);
        for (uint256 i; i < MARKETS; ++i) {
            _owner(string.concat("  ", r.markets[i].symbol, " feed owner"), r.markets[i].feed);
        }
        SiliconVault vault = SiliconVault(r.vault);
        for (uint256 i; i < MARKETS; ++i) {
            console2.log(string.concat("  ", r.markets[i].symbol, " open"), vault.market(i).open);
        }
    }

    function _owner(string memory label, address account) private view {
        Ownable2Step c = Ownable2Step(account);
        if (c.pendingOwner() == address(0)) console2.log(label, c.owner());
        else console2.log(string.concat(label, " (to accept: acceptOwnership from)"), c.pendingOwner());
    }
}
