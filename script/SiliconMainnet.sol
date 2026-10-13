// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {KyznUsdOracle} from "../src/silicon/KyznUsdOracle.sol";
import {MarketCalendar} from "../src/silicon/MarketCalendar.sol";
import {SiliconFeeRouter} from "../src/silicon/SiliconFeeRouter.sol";
import {SiliconSwapAdapter} from "../src/silicon/SiliconSwapAdapter.sol";
import {SiliconSynth} from "../src/silicon/SiliconSynth.sol";
import {SiliconVault} from "../src/silicon/SiliconVault.sol";
import {StockIndexFeed} from "../src/silicon/StockIndexFeed.sol";
import {IKyznUsdOracle} from "../src/silicon/interfaces/IKyznUsdOracle.sol";
import {IMarketCalendar} from "../src/silicon/interfaces/IMarketCalendar.sol";
import {ISiliconFeed} from "../src/silicon/interfaces/ISiliconFeed.sol";
import {ISiliconSynth} from "../src/silicon/interfaces/ISiliconSynth.sol";
import {IV3SwapRouter02, IV4PoolManager} from "../src/silicon/interfaces/ISwapVenues.sol";
import {IUniswapV2PairTwap} from "../src/silicon/interfaces/IUniswapV2PairTwap.sol";
import {RobinhoodChain} from "./RobinhoodChain.sol";

/// @notice Arbitrum's ArbSys precompile, as far as the deployment needs it. On Robinhood Chain (an
/// Arbitrum chain) `block.number` inside a contract is the parent chain's block number; the chain's
/// own block number, the one its RPC and logs use, comes from ArbSys.
interface IArbSys {
    function arbBlockNumber() external view returns (uint256);
}

/// @title Kyzen Network Silicon stock indices deployment
/// @notice The four chip-stock stage indices of SPEC 3.5's opening set, deployed and configured in
/// one transaction from the owner wallet. Deploying this contract:
///   1. deploys the MarketCalendar and marks every exchange holiday (closed) and early close
///      (window ends 17:00 UTC) of the setup;
///   2. deploys the $KYZN oracle on the $KYZN/WETH pair and Chainlink ETH/USD;
///   3. deploys the vault ($KYZN and USDG as collateral) and the fee router (the Reserve's share to
///      the Reserve, the rest to Staking, the keeper named), and the swap adapter (Uniswap v4
///      PoolManager, v3 SwapRouter02, WETH, USDG; no owner), which it queues as the fee router's
///      swap target while it still owns the router: the router's 24-hour delay starts with the
///      deployment, and the adapter is a live target from then on, with nothing more to send;
///   4. per index, deploys its synth and its StockIndexFeed on the Chainlink feeds of its basket
///      (equal dollar weights, starting at $100), names the owner its guardian, publishes its
///      methodology (the text's URI and keccak-256), adds the market and sets the market's levels:
///      mint fee, borrow fee, liquidation penalty, and the debt ceiling and minimum debt as synth
///      worth the setup's USD amounts at the index's price now (the ceiling rounded down, the
///      minimum rounded up);
///   5. sets the vault-wide levels (auction duration, starting premium, floor, fee router) and
///      names the owner the vault's guardian;
///   6. offers the owner ownership of the calendar, the vault, the fee router and the four feeds,
///      each taking effect when the owner calls `acceptOwnership` on it (Ownable2Step).
/// No market is opened: SPEC 3.5 opens them once the pool has depth and the oracle 24 hours of
/// observations, by the owner's `openMarket` on the vault. Every level is set before any market
/// opens, so each takes effect at once; once one is open, the owner's changes to the settings that
/// bear on open positions wait 24 hours in public (SiliconVault).
/// This contract keeps nothing and has no function that can change anything; its views name what
/// it deployed, and `Deployed` names it all with the chain's block number, for the record.
/// @dev The deployer must be the setup's owner, so a copy deployed by anyone else cannot pass for
/// the real one: deployed through a factory, it reverts NotOwner.
contract SiliconDeployment {
    /// The opening set: Design, Memory, Fab and Equipment (SPEC 3.5).
    uint256 public constant MARKETS = 4;

    /// One index: its names, the Chainlink feeds of its basket, and its published methodology.
    struct Index {
        /// "Design": the synth is "Kyzen Network Design index", the feed "Kyzen Network Design index / USD".
        string name;
        /// "kDESIGN".
        string symbol;
        address[] feeds;
        string methodologyURI;
        bytes32 methodologyHash;
    }

    /// The levels (SPEC 3.5), per market except the last three, which are vault-wide.
    struct Levels {
        uint256 mintFeeBps;
        uint256 borrowFeeBpsPerYear;
        uint256 liquidationPenaltyBps;
        /// USD, 18 decimals: the debt ceiling is the synth worth this at the index's price now.
        uint256 debtCeilingUsd;
        /// USD, 18 decimals: the minimum debt is the synth worth this at the index's price now.
        uint256 minDebtUsd;
        uint256 auctionDuration;
        uint256 auctionStartPremiumBps;
        uint256 auctionFloorBps;
    }

    /// Everything the deployment needs. SiliconMainnet fills it for Robinhood Chain.
    struct Setup {
        /// Must send the deployment; owns everything and is the guardian.
        address owner;
        address kyzn;
        address usdg;
        /// The Uniswap v2 $KYZN/WETH pair.
        address pair;
        address ethUsdFeed;
        address weth;
        uint256 oracleShortWindow;
        uint256 oracleLongWindow;
        address reserve;
        address staking;
        /// Runs the fee router's conversions.
        address keeper;
        /// The Uniswap v4 PoolManager and v3 SwapRouter02, the swap adapter's venues.
        address v4PoolManager;
        address swapRouter02;
        uint256 reserveShareBps;
        Levels levels;
        /// UTC day numbers (timestamp / 86400).
        uint256[] closedDays;
        uint256[] earlyCloseDays;
        Index[MARKETS] indices;
    }

    /// What the constructor deployed, before it is copied to the immutables.
    struct Deployment {
        MarketCalendar calendar;
        KyznUsdOracle oracle;
        SiliconVault vault;
        SiliconFeeRouter feeRouter;
        SiliconSwapAdapter swapAdapter;
        SiliconSynth[MARKETS] synths;
        StockIndexFeed[MARKETS] feeds;
    }

    /// @notice The wallet that deployed this and is offered ownership of everything.
    address public immutable owner;
    /// @notice The minting calendar.
    MarketCalendar public immutable calendar;
    /// @notice The $KYZN/USD oracle.
    KyznUsdOracle public immutable oracle;
    /// @notice The vault.
    SiliconVault public immutable vault;
    /// @notice The fee router.
    SiliconFeeRouter public immutable feeRouter;
    /// @notice The fee router's swap target, queued at deployment.
    SiliconSwapAdapter public immutable swapAdapter;
    /// @notice The chain's block number of this deployment (on Robinhood Chain, from ArbSys).
    uint256 public immutable deployBlock;

    SiliconSynth private immutable _synth0;
    SiliconSynth private immutable _synth1;
    SiliconSynth private immutable _synth2;
    SiliconSynth private immutable _synth3;
    StockIndexFeed private immutable _feed0;
    StockIndexFeed private immutable _feed1;
    StockIndexFeed private immutable _feed2;
    StockIndexFeed private immutable _feed3;

    /// @notice Everything was deployed, configured and offered to `owner`; market `i` is
    /// `synths[i]` priced by `feeds[i]`. `deployBlock` is the chain's block number.
    event Deployed(
        address indexed owner,
        MarketCalendar calendar,
        KyznUsdOracle oracle,
        SiliconVault vault,
        SiliconFeeRouter feeRouter,
        SiliconSwapAdapter swapAdapter,
        SiliconSynth[4] synths,
        StockIndexFeed[4] feeds,
        uint256 deployBlock
    );

    /// @notice The deployer is not the setup's owner.
    error NotOwner(address sender, address owner);
    /// @notice The deployment runs on another chain than Robinhood Chain.
    error WrongChain(uint256 chainId);
    /// @notice The vault gave market `id` another number.
    error MarketMismatch(uint256 id);
    /// @notice The index prices at zero, so no ceiling or minimum can be set.
    error ZeroPrice(uint256 id);
    /// @notice Market `id` would still miss the settings in `unset` (SiliconVault's bits).
    error MarketNotReady(uint256 id, uint16 unset);

    constructor(Setup memory s) {
        if (msg.sender != s.owner) revert NotOwner(msg.sender, s.owner);
        Deployment memory d;
        _deployCore(s, d);
        for (uint256 i; i < MARKETS; ++i) {
            _deployMarket(s, d, i);
        }
        _configureVault(s, d);
        _offer(s.owner, d);

        owner = s.owner;
        calendar = d.calendar;
        oracle = d.oracle;
        vault = d.vault;
        feeRouter = d.feeRouter;
        swapAdapter = d.swapAdapter;
        _synth0 = d.synths[0];
        _synth1 = d.synths[1];
        _synth2 = d.synths[2];
        _synth3 = d.synths[3];
        _feed0 = d.feeds[0];
        _feed1 = d.feeds[1];
        _feed2 = d.feeds[2];
        _feed3 = d.feeds[3];
        uint256 blockNumber = _blockNumber();
        deployBlock = blockNumber;
        emit Deployed(
            s.owner, d.calendar, d.oracle, d.vault, d.feeRouter, d.swapAdapter, d.synths, d.feeds, blockNumber
        );
    }

    // ---------------------------------------------------------------- views

    /// @notice The four synths, by market id.
    function synths() external view returns (SiliconSynth[4] memory list) {
        list[0] = _synth0;
        list[1] = _synth1;
        list[2] = _synth2;
        list[3] = _synth3;
    }

    /// @notice The four index feeds, by market id.
    function feeds() external view returns (StockIndexFeed[4] memory list) {
        list[0] = _feed0;
        list[1] = _feed1;
        list[2] = _feed2;
        list[3] = _feed3;
    }

    // ---------------------------------------------------------------- deployment

    /// The calendar with its days, the oracle, the vault, the fee router and its swap adapter.
    function _deployCore(Setup memory s, Deployment memory d) private {
        d.calendar = new MarketCalendar(address(this));
        d.calendar.setDays(s.closedDays, MarketCalendar.DayKind.Closed);
        d.calendar.setDays(s.earlyCloseDays, MarketCalendar.DayKind.EarlyClose);

        d.oracle = new KyznUsdOracle(
            IUniswapV2PairTwap(s.pair), s.kyzn, s.ethUsdFeed, s.oracleShortWindow, s.oracleLongWindow
        );
        d.vault = new SiliconVault(IERC20(s.kyzn), IERC20(s.usdg), IKyznUsdOracle(address(d.oracle)));

        d.feeRouter = new SiliconFeeRouter(IWETH(s.weth));
        d.feeRouter.setReserve(s.reserve);
        d.feeRouter.setStaking(s.staking);
        d.feeRouter.setSplit(s.reserveShareBps);
        d.feeRouter.setKeeper(s.keeper);

        d.swapAdapter =
            new SiliconSwapAdapter(IV4PoolManager(s.v4PoolManager), IV3SwapRouter02(s.swapRouter02), s.weth, s.usdg);
        d.feeRouter.queueTarget(address(d.swapAdapter), true);
    }

    /// Market `i`: its synth and index feed, added to the vault with the market's levels.
    function _deployMarket(Setup memory s, Deployment memory d, uint256 i) private {
        Index memory x = s.indices[i];
        SiliconSynth synth =
            new SiliconSynth(string.concat("Kyzen Network ", x.name, " index"), x.symbol, address(d.vault));
        StockIndexFeed feed = new StockIndexFeed(
            string.concat("Kyzen Network ", x.name, " index / USD"),
            IMarketCalendar(address(d.calendar)),
            x.feeds,
            address(this)
        );
        feed.setGuardian(s.owner);
        feed.setMethodology(x.methodologyURI, x.methodologyHash);
        d.synths[i] = synth;
        d.feeds[i] = feed;

        SiliconVault vault_ = d.vault;
        uint256 id = vault_.addMarket(ISiliconSynth(address(synth)), ISiliconFeed(address(feed)));
        if (id != i) revert MarketMismatch(id);
        (uint256 price,) = feed.latestPrice();
        if (price == 0) revert ZeroPrice(id);
        Levels memory l = s.levels;
        vault_.setMintFee(id, l.mintFeeBps);
        vault_.setBorrowFee(id, l.borrowFeeBpsPerYear);
        vault_.setLiquidationPenalty(id, l.liquidationPenaltyBps);
        // Synth units (18 decimals) worth the USD amounts at the index's price now: the ceiling
        // rounded down and the minimum rounded up, so neither is ever worth more (the ceiling) or
        // less (the minimum) than the level says.
        vault_.setDebtCeiling(id, Math.mulDiv(l.debtCeilingUsd, 1e18, price));
        vault_.setMinDebt(id, Math.mulDiv(l.minDebtUsd, 1e18, price, Math.Rounding.Ceil));
    }

    /// The vault-wide levels and the guardian; then every market must have all its settings.
    function _configureVault(Setup memory s, Deployment memory d) private {
        SiliconVault vault_ = d.vault;
        vault_.setAuctionDuration(s.levels.auctionDuration);
        vault_.setAuctionStartPremium(s.levels.auctionStartPremiumBps);
        vault_.setAuctionFloor(s.levels.auctionFloorBps);
        vault_.setFeeRouter(address(d.feeRouter));
        vault_.setGuardian(s.owner);
        for (uint256 id; id < MARKETS; ++id) {
            uint16 unset = vault_.unsetSettings(id);
            if (unset != 0) revert MarketNotReady(id, unset);
        }
    }

    /// Offers `to` ownership of every contract that has an owner.
    function _offer(address to, Deployment memory d) private {
        d.calendar.transferOwnership(to);
        d.vault.transferOwnership(to);
        d.feeRouter.transferOwnership(to);
        for (uint256 i; i < MARKETS; ++i) {
            d.feeds[i].transferOwnership(to);
        }
    }

    /// The chain's block number now: `block.number` here; SiliconMainnet asks ArbSys.
    function _blockNumber() internal view virtual returns (uint256) {
        return block.number;
    }
}

/// @title The terms of the Silicon stock indices on Robinhood Chain mainnet
/// @notice Every value SiliconMainnet deploys with: the chain's contracts, the owner's wallets and
/// SPEC 3.5's levels (owner decisions). A library, so the recorder and the tests read the same
/// constants.
library SiliconMainnetTerms {
    /// The owner wallet: deploys the token and the protocol, and owns them (SPEC Step 4).
    address internal constant OWNER = 0x965200078d41c1B91CED2f842106662d8bDdd16e;
    /// $KYZN.
    address internal constant KYZN = 0x9b3A765a32F3ff0623a2dEa04136960C77205B09;
    /// The Uniswap v2 $KYZN/WETH pair the token created.
    address internal constant PAIR = 0x49449B585e5D05f3aCFF985c4978147FA0593665;
    /// USDG (Global Dollar), 6 decimals, valued at $1.00 (SPEC 3.5).
    address internal constant USDG = RobinhoodChain.USDG;
    /// The Reserve, paid two thirds of the fees.
    address internal constant RESERVE = 0x8112e96d514787BDDA67E6A6B2432Ab229a1045e;
    /// Staking, paid one third once its owner names the fee router as its fee source.
    address internal constant STAKING = 0x76E274064f6d047206D3d164332D143C52a08c0a;
    /// The server's keeper wallet, the Reserve's keeper (contracts/deployments/4663.json).
    address internal constant KEEPER = 0x9773407713fe52BfF54C5E3f519A5EA4F7334538;
    /// Arbitrum's ArbSys precompile.
    address internal constant ARB_SYS = address(0x64);

    /// The oracle's averages on mainnet: 1 hour and 24 hours (SPEC 3.5).
    uint256 internal constant ORACLE_SHORT_WINDOW = 1 hours;
    uint256 internal constant ORACLE_LONG_WINDOW = 24 hours;
    /// Fees: two thirds to the Reserve, one third to stakers (SPEC 3.5).
    uint256 internal constant RESERVE_SHARE_BPS = 6_667;
    /// The levels of SPEC 3.5.
    uint256 internal constant MINT_FEE_BPS = 50; // 0.5% of each mint
    uint256 internal constant BORROW_FEE_BPS_PER_YEAR = 1_200; // 12% a year
    uint256 internal constant LIQUIDATION_PENALTY_BPS = 1_300; // 13%
    uint256 internal constant DEBT_CEILING_USD = 25_000e18; // $25,000 of synth per market at opening
    uint256 internal constant MIN_DEBT_USD = 500e18; // $500 of synth per position
    uint256 internal constant AUCTION_DURATION = 100 minutes;
    uint256 internal constant AUCTION_START_PREMIUM_BPS = 2_000; // from 20% above the oracle value
    uint256 internal constant AUCTION_FLOOR_BPS = 7_600; // never below 76% of it

    /// Each index's methodology text is served byte for byte at METHODOLOGY_BASE<slug>.txt; its
    /// keccak-256 (methodology-hashes.json, written by
    /// scripts/methodology-hashes.mjs; scripts/silicon-mainnet.test.mjs holds these to it).
    string internal constant METHODOLOGY_BASE = "https://docs.kyzen.network/methodology/";
    bytes32 internal constant KDESIGN_METHODOLOGY_HASH =
        0xce8fc786166960ff6fd07889bdc00444734b09b676eb5735cdc81d73e10f6629;
    bytes32 internal constant KMEMORY_METHODOLOGY_HASH =
        0x79ca695059f495b8b688a00c56d88bb0a8a1f4fdbd18d39fd01553a04fa53338;
    bytes32 internal constant KFAB_METHODOLOGY_HASH =
        0x65057983771d7d30c3841ad98d68fccadf4f1a1bf25f2f89328c8bbedf0637d4;
    bytes32 internal constant KEQUIP_METHODOLOGY_HASH =
        0xce3f1c20c8cff3b0d475d77ab50d47e5311f686ae1e740d10d510e3a41e4bcca;

    /// The exchange holidays (closed all day), as UTC day numbers: script/market-calendar.json
    /// (scripts/market-calendar.mjs, through 2028-12-31); test/SiliconMainnet.t.sol holds them to
    /// the file.
    function closedDays() internal pure returns (uint256[] memory d) {
        d = new uint256[](21);
        d[0] = 20783; // 2026-11-26
        d[1] = 20812; // 2026-12-25
        d[2] = 20819; // 2027-01-01
        d[3] = 20836; // 2027-01-18
        d[4] = 20864; // 2027-02-15
        d[5] = 20903; // 2027-03-26
        d[6] = 20969; // 2027-05-31
        d[7] = 20987; // 2027-06-18
        d[8] = 21004; // 2027-07-05
        d[9] = 21067; // 2027-09-06
        d[10] = 21147; // 2027-11-25
        d[11] = 21176; // 2027-12-24
        d[12] = 21200; // 2028-01-17
        d[13] = 21235; // 2028-02-21
        d[14] = 21288; // 2028-04-14
        d[15] = 21333; // 2028-05-29
        d[16] = 21354; // 2028-06-19
        d[17] = 21369; // 2028-07-04
        d[18] = 21431; // 2028-09-04
        d[19] = 21511; // 2028-11-23
        d[20] = 21543; // 2028-12-25
    }

    /// The early closes (the window ends at 17:00 UTC), as UTC day numbers, from the same file.
    function earlyCloseDays() internal pure returns (uint256[] memory d) {
        d = new uint256[](5);
        d[0] = 20784; // 2026-11-27
        d[1] = 20811; // 2026-12-24
        d[2] = 21148; // 2027-11-26
        d[3] = 21368; // 2028-07-03
        d[4] = 21512; // 2028-11-24
    }

    /// Market `id`'s Chainlink feeds: Design NVDA and AMD, Memory MU and SNDK, Fab TSM and INTC,
    /// Equipment ASML (SPEC 3.5).
    function basket(uint256 id) internal pure returns (address[] memory b) {
        b = new address[](id == 3 ? 1 : 2);
        if (id == 0) (b[0], b[1]) = (RobinhoodChain.NVDA_USD, RobinhoodChain.AMD_USD);
        else if (id == 1) (b[0], b[1]) = (RobinhoodChain.MU_USD, RobinhoodChain.SNDK_USD);
        else if (id == 2) (b[0], b[1]) = (RobinhoodChain.TSM_USD, RobinhoodChain.INTC_USD);
        else b[0] = RobinhoodChain.ASML_USD;
    }

    /// Market `id`'s index: its name, symbol, basket and methodology.
    function index(uint256 id) internal pure returns (SiliconDeployment.Index memory x) {
        string memory slug;
        if (id == 0) {
            (x.name, x.symbol, slug, x.methodologyHash) = ("Design", "kDESIGN", "kdesign", KDESIGN_METHODOLOGY_HASH);
        } else if (id == 1) {
            (x.name, x.symbol, slug, x.methodologyHash) = ("Memory", "kMEMORY", "kmemory", KMEMORY_METHODOLOGY_HASH);
        } else if (id == 2) {
            (x.name, x.symbol, slug, x.methodologyHash) = ("Fab", "kFAB", "kfab", KFAB_METHODOLOGY_HASH);
        } else {
            (x.name, x.symbol, slug, x.methodologyHash) = ("Equipment", "kEQUIP", "kequip", KEQUIP_METHODOLOGY_HASH);
        }
        x.feeds = basket(id);
        x.methodologyURI = string.concat(METHODOLOGY_BASE, slug, ".txt");
    }

    /// Every value of the deployment, on Robinhood Chain only.
    function setup() internal view returns (SiliconDeployment.Setup memory s) {
        if (block.chainid != RobinhoodChain.CHAIN_ID) revert SiliconDeployment.WrongChain(block.chainid);
        s.owner = OWNER;
        s.kyzn = KYZN;
        s.usdg = USDG;
        s.pair = PAIR;
        s.ethUsdFeed = RobinhoodChain.ETH_USD_FEED;
        s.weth = RobinhoodChain.WETH;
        s.oracleShortWindow = ORACLE_SHORT_WINDOW;
        s.oracleLongWindow = ORACLE_LONG_WINDOW;
        s.reserve = RESERVE;
        s.staking = STAKING;
        s.keeper = KEEPER;
        s.v4PoolManager = RobinhoodChain.UNISWAP_V4_POOL_MANAGER;
        s.swapRouter02 = RobinhoodChain.UNISWAP_V3_SWAP_ROUTER_02;
        s.reserveShareBps = RESERVE_SHARE_BPS;
        s.levels = SiliconDeployment.Levels({
            mintFeeBps: MINT_FEE_BPS,
            borrowFeeBpsPerYear: BORROW_FEE_BPS_PER_YEAR,
            liquidationPenaltyBps: LIQUIDATION_PENALTY_BPS,
            debtCeilingUsd: DEBT_CEILING_USD,
            minDebtUsd: MIN_DEBT_USD,
            auctionDuration: AUCTION_DURATION,
            auctionStartPremiumBps: AUCTION_START_PREMIUM_BPS,
            auctionFloorBps: AUCTION_FLOOR_BPS
        });
        s.closedDays = closedDays();
        s.earlyCloseDays = earlyCloseDays();
        for (uint256 i; i < s.indices.length; ++i) {
            s.indices[i] = index(i);
        }
    }
}

/// @title Kyzen Network Silicon stock indices on Robinhood Chain mainnet
/// @notice The four indices on Robinhood Chain (chain ID 4663) at SPEC 3.5's levels, for $KYZN and
/// USDG collateral, with every value from SiliconMainnetTerms; see SiliconDeployment for every
/// step. The owner deploys it with no arguments, from the owner wallet, once $KYZN has liquidity.
contract SiliconMainnet is SiliconDeployment {
    constructor() SiliconDeployment(SiliconMainnetTerms.setup()) {}

    /// Robinhood Chain's own block number, from ArbSys.
    function _blockNumber() internal view override returns (uint256) {
        return IArbSys(SiliconMainnetTerms.ARB_SYS).arbBlockNumber();
    }
}
