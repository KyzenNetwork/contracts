// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketCalendar} from "../src/silicon/MarketCalendar.sol";
import {SiliconSwapAdapter} from "../src/silicon/SiliconSwapAdapter.sol";
import {SiliconSynth} from "../src/silicon/SiliconSynth.sol";
import {SiliconVault} from "../src/silicon/SiliconVault.sol";
import {StockIndexFeed} from "../src/silicon/StockIndexFeed.sol";
import {SiliconDeployment, SiliconMainnet, SiliconMainnetTerms as Terms} from "../script/SiliconMainnet.sol";
import {SiliconMainnetOpen} from "../script/SiliconMainnetOpen.s.sol";
import {RecordSiliconMainnet} from "../script/RecordSiliconMainnet.s.sol";
import {RobinhoodChain as RH} from "../script/RobinhoodChain.sol";
import {MockToken} from "./silicon/mocks/SiliconMocks.sol";
import {MockWETH} from "./mocks/MockWETH.sol";
import {MockFeed} from "./mocks/MockFeed.sol";

interface IUniswapV2FactoryCreatePair {
    function createPair(address tokenA, address tokenB) external returns (address pair);
}

interface IUniswapV2PairMint {
    function mint(address to) external returns (uint256 liquidity);
}

/// Staking's fee source, as the opening check reads it.
contract StakingFeeSourceStub {
    address public feeSource;

    function setFeeSource(address source) external {
        feeSource = source;
    }
}

/// The Silicon mainnet deployment (script/SiliconMainnet.sol) offline. SiliconDeployment runs
/// with stand-ins: $KYZN, USDG (6 decimals) and WETH, the official Uniswap v2 factory (the
/// unmodified build in external/uniswap-v2) for the pair, and Chainlink-shaped feeds for ETH/USD
/// and the seven stocks. SiliconMainnet's own terms are checked against SPEC 3.5 and
/// script/market-calendar.json; test/fork/SiliconMainnet.t.sol deploys it on a fork of mainnet.
contract SiliconMainnetTest is Test {
    /// Thursday 1 October 2026, 12:00 UTC.
    uint256 internal constant DEPLOYED_AT = 1_790_856_000;

    address internal owner = makeAddr("owner");
    address internal reserve = makeAddr("reserve");
    /// Staking's fee source, settable (StakingFeeSourceStub).
    address internal staking;
    address internal keeper = makeAddr("keeper");
    address internal poolManager = makeAddr("poolManager");
    address internal swapRouter02 = makeAddr("swapRouter02");
    address internal stranger = makeAddr("stranger");

    MockToken internal kyzn;
    MockToken internal usdg;
    MockWETH internal weth;
    address internal pair;
    MockFeed internal ethUsd;
    /// NVDA, AMD, MU, SNDK, TSM, INTC, ASML, as Terms.basket lists them.
    MockFeed[7] internal stocks;

    function setUp() public {
        vm.warp(DEPLOYED_AT);
        staking = address(new StakingFeeSourceStub());
        kyzn = new MockToken("KYZN", 18);
        usdg = new MockToken("USDG", 6);
        weth = new MockWETH();
        address factory = deployCode("external/uniswap-v2/UniswapV2Factory.json", abi.encode(address(this)));
        pair = IUniswapV2FactoryCreatePair(factory).createPair(address(kyzn), address(weth));
        ethUsd = new MockFeed(8, 2_500e8);
        int256[7] memory prices = [int256(180e8), 160e8, 110e8, 45e8, 190e8, 21e8, 700e8];
        for (uint256 i; i < stocks.length; ++i) {
            stocks[i] = new MockFeed(8, prices[i]);
        }
    }

    // ---------------------------------------------------------------- the mainnet terms

    /// SPEC 3.5's levels and the opening set, as SiliconMainnet deploys them.
    function test_the_mainnet_terms_are_spec_3_5() public pure {
        assertEq(Terms.ORACLE_SHORT_WINDOW, 1 hours);
        assertEq(Terms.ORACLE_LONG_WINDOW, 24 hours);
        assertEq(Terms.RESERVE_SHARE_BPS, 6_667, "two thirds to the Reserve");
        assertEq(Terms.MINT_FEE_BPS, 50, "0.5%");
        assertEq(Terms.BORROW_FEE_BPS_PER_YEAR, 1_200, "12% a year");
        assertEq(Terms.LIQUIDATION_PENALTY_BPS, 1_300, "13%");
        assertEq(Terms.DEBT_CEILING_USD, 25_000e18);
        assertEq(Terms.MIN_DEBT_USD, 500e18);
        assertEq(Terms.AUCTION_DURATION, 100 minutes);
        assertEq(Terms.AUCTION_START_PREMIUM_BPS, 2_000, "from 20% above");
        assertEq(Terms.AUCTION_FLOOR_BPS, 7_600, "never below 76%");
        // The floor covers what a position at 150% owes plus the penalty (SPEC 3.5).
        assertGe(Terms.AUCTION_FLOOR_BPS * 15_000, (10_000 + Terms.LIQUIDATION_PENALTY_BPS) * 10_000);

        string[4] memory names = ["Design", "Memory", "Fab", "Equipment"];
        string[4] memory symbols = ["kDESIGN", "kMEMORY", "kFAB", "kEQUIP"];
        string[4] memory uris = [
            "https://docs.kyzen.network/methodology/kdesign.txt",
            "https://docs.kyzen.network/methodology/kmemory.txt",
            "https://docs.kyzen.network/methodology/kfab.txt",
            "https://docs.kyzen.network/methodology/kequip.txt"
        ];
        for (uint256 id; id < 4; ++id) {
            SiliconDeployment.Index memory x = Terms.index(id);
            assertEq(x.name, names[id]);
            assertEq(x.symbol, symbols[id]);
            assertEq(x.methodologyURI, uris[id]);
            assertTrue(x.methodologyHash != bytes32(0));
        }
        _assertBasket(0, RH.NVDA_USD, RH.AMD_USD);
        _assertBasket(1, RH.MU_USD, RH.SNDK_USD);
        _assertBasket(2, RH.TSM_USD, RH.INTC_USD);
        address[] memory equipment = Terms.index(3).feeds;
        assertEq(equipment.length, 1);
        assertEq(equipment[0], RH.ASML_USD);
    }

    /// Every closed day and early close of script/market-calendar.json, and nothing else.
    function test_the_calendar_days_are_the_files() public view {
        string memory json = vm.readFile("script/market-calendar.json");
        assertEq(Terms.closedDays(), abi.decode(vm.parseJson(json, ".closed[*].day"), (uint256[])));
        assertEq(Terms.earlyCloseDays(), abi.decode(vm.parseJson(json, ".earlyClose[*].day"), (uint256[])));
    }

    function test_mainnet_deploys_only_on_robinhood_chain() public {
        vm.prank(Terms.OWNER);
        vm.expectRevert(abi.encodeWithSelector(SiliconDeployment.WrongChain.selector, block.chainid));
        new SiliconMainnet();
    }

    // ---------------------------------------------------------------- the deployment

    function test_deploys_configures_and_offers_everything_to_the_owner() public {
        SiliconDeployment.Setup memory s = _setup();
        vm.recordLogs();
        vm.prank(owner);
        SiliconDeployment d = new SiliconDeployment(s);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(d.owner(), owner);
        assertEq(d.deployBlock(), block.number);
        SiliconVault vault = d.vault();
        MarketCalendar calendar = d.calendar();
        SiliconSynth[4] memory synths = d.synths();
        StockIndexFeed[4] memory feeds = d.feeds();

        // One Deployed event with every address.
        Vm.Log memory deployed = logs[logs.length - 1];
        assertEq(deployed.topics[0], SiliconDeployment.Deployed.selector);
        assertEq(deployed.topics[1], bytes32(uint256(uint160(owner))));
        assertEq(
            deployed.data,
            abi.encode(
                d.calendar(),
                d.oracle(),
                vault,
                d.feeRouter(),
                d.swapAdapter(),
                _addresses(synths),
                _feedAddresses(feeds),
                block.number
            )
        );

        // Offered to the owner; the deployment keeps nothing it could use.
        address[7] memory owned = [
            address(calendar),
            address(vault),
            address(d.feeRouter()),
            address(feeds[0]),
            address(feeds[1]),
            address(feeds[2]),
            address(feeds[3])
        ];
        for (uint256 i; i < owned.length; ++i) {
            assertEq(Ownable2Step(owned[i]).pendingOwner(), owner);
            vm.prank(owner);
            Ownable2Step(owned[i]).acceptOwnership();
            assertEq(Ownable(owned[i]).owner(), owner);
        }

        // Calendar, oracle and fee router.
        assertEq(uint8(calendar.dayKind(Terms.closedDays()[0])), uint8(MarketCalendar.DayKind.Closed));
        assertEq(uint8(calendar.dayKind(Terms.earlyCloseDays()[0])), uint8(MarketCalendar.DayKind.EarlyClose));
        assertEq(address(d.oracle().pair()), pair);
        assertEq(d.oracle().shortWindow(), 1 hours);
        assertEq(d.oracle().longWindow(), 24 hours);
        assertEq(d.feeRouter().reserve(), reserve);
        assertEq(d.feeRouter().staking(), staking);
        assertEq(d.feeRouter().keeper(), keeper);
        assertEq(d.feeRouter().reserveShareBps(), 6_667);

        // The vault and its four markets, closed, every setting set.
        assertEq(vault.guardian(), owner);
        assertEq(vault.feeRouter(), address(d.feeRouter()));
        assertEq(vault.auctionDuration(), 100 minutes);
        assertEq(vault.auctionStartPremiumBps(), 2_000);
        assertEq(vault.auctionFloorBps(), 7_600);
        assertEq(vault.usdgScale(), 1e12);
        assertEq(vault.marketCount(), 4);
        for (uint256 id; id < 4; ++id) {
            SiliconVault.Market memory m = vault.market(id);
            assertEq(address(m.synth), address(synths[id]));
            assertEq(address(m.feed), address(feeds[id]));
            assertFalse(m.open);
            assertEq(m.mintFeeBps, 50);
            assertEq(m.borrowFeeBpsPerYear, 1_200);
            assertEq(m.liquidationPenaltyBps, 1_300);
            (uint256 price,) = feeds[id].latestPrice();
            assertApproxEqAbs(price, 100e18, 1e10);
            assertEq(m.debtCeiling, Math.mulDiv(25_000e18, 1e18, price));
            assertEq(m.minDebt, Math.mulDiv(500e18, 1e18, price, Math.Rounding.Ceil));
            assertEq(vault.unsetSettings(id), 0);
            assertEq(feeds[id].guardian(), owner);
            assertEq(feeds[id].methodologyURI(), s.indices[id].methodologyURI);
            assertEq(feeds[id].methodologyHash(), s.indices[id].methodologyHash);
            assertEq(synths[id].symbol(), s.indices[id].symbol);
            assertEq(synths[id].name(), string.concat("Kyzen Network ", s.indices[id].name, " index"));
            assertEq(feeds[id].description(), string.concat("Kyzen Network ", s.indices[id].name, " index / USD"));
        }

        // The swap adapter, on the setup's venues, queued as the fee router's target: live 24 hours
        // after the deployment, with nothing more to send.
        SiliconSwapAdapter adapter = d.swapAdapter();
        assertEq(address(adapter.poolManager()), poolManager);
        assertEq(address(adapter.swapRouter()), swapRouter02);
        assertEq(adapter.weth(), address(weth));
        assertEq(adapter.usdg(), address(usdg));
        assertEq(adapter.weth(), address(d.feeRouter().weth()), "the WETH the router counts");
        assertEq(adapter.usdg(), address(vault.usdg()), "the vault's USDG");
        (bool queued, uint256 effectiveAt) = d.feeRouter().pendingTarget(address(adapter));
        assertTrue(queued);
        assertEq(effectiveAt, DEPLOYED_AT + 24 hours);
        assertFalse(d.feeRouter().isTargetAllowed(address(adapter)));

        // The owner opens a market once accepted; no one else can.
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        vault.openMarket(0);
        vm.prank(owner);
        vault.openMarket(0);
        assertTrue(vault.market(0).open);

        vm.warp(DEPLOYED_AT + 24 hours - 1);
        assertFalse(d.feeRouter().isTargetAllowed(address(adapter)));
        vm.warp(DEPLOYED_AT + 24 hours);
        assertTrue(d.feeRouter().isTargetAllowed(address(adapter)), "the adapter is the router's target");
    }

    /// The swap adapter's venues on mainnet: the v4 PoolManager and v3 SwapRouter02 of
    /// RobinhoodChain (SPEC 3.2a), WETH and USDG.
    function test_the_mainnet_adapter_venues() public {
        vm.chainId(RH.CHAIN_ID);
        SiliconDeployment.Setup memory s = Terms.setup();
        assertEq(s.v4PoolManager, RH.UNISWAP_V4_POOL_MANAGER);
        assertEq(s.swapRouter02, RH.UNISWAP_V3_SWAP_ROUTER_02);
        assertEq(s.swapRouter02, 0xCaf681a66D020601342297493863E78C959E5cb2);
        assertEq(s.weth, RH.WETH);
        assertEq(s.usdg, RH.USDG);
    }

    function test_only_the_setups_owner_deploys_it() public {
        SiliconDeployment.Setup memory s = _setup();
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(SiliconDeployment.NotOwner.selector, stranger, owner));
        new SiliconDeployment(s);
    }

    /// A feed without its methodology is not ready, so its market could never open: the
    /// deployment refuses it rather than leave it half made.
    function test_refuses_a_market_that_could_not_open() public {
        SiliconDeployment.Setup memory s = _setup();
        s.indices[2].methodologyHash = bytes32(0);
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SiliconDeployment.MarketNotReady.selector, 2, 128));
        new SiliconDeployment(s);
    }

    /// An index that prices at zero (a component dated in the future reads as unreadable) leaves
    /// no ceiling or minimum to set.
    function test_refuses_an_index_without_a_price() public {
        stocks[6].set(700e8, block.timestamp + 1);
        SiliconDeployment.Setup memory s = _setup();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(SiliconDeployment.ZeroPrice.selector, 3));
        new SiliconDeployment(s);
    }

    // ---------------------------------------------------------------- the opening check

    /// SiliconMainnetOpen on a deployment with a deep pool: nothing to open before the owner owns
    /// everything and the oracle prices $KYZN; then each market whose ceiling is within the pool's
    /// $KYZN side, the sum of the ceilings beside it (not refused); a stale or unpriced index
    /// stops the whole list.
    function test_the_opening_check_lists_only_what_may_open() public {
        // 1,000,000 $KYZN and 20 ETH at $2,500: $KYZN at $0.05, a $KYZN side of $50,000.
        kyzn.mint(pair, 1_000_000e18);
        vm.deal(address(this), 20 ether);
        weth.deposit{value: 20 ether}();
        weth.transfer(pair, 20 ether);
        IUniswapV2PairMint(pair).mint(owner);

        vm.prank(owner);
        SiliconDeployment d = new SiliconDeployment(_setup());
        SiliconVault vault = d.vault();
        SiliconMainnetOpen check = new SiliconMainnetOpen();
        SiliconSwapAdapter adapter = d.swapAdapter();
        assertFalse(check.adapterStatus(adapter, vault, poolManager, swapRouter02), "not a target yet");
        vm.expectRevert(abi.encodeWithSelector(SiliconMainnetOpen.AdapterMismatch.selector, address(adapter)));
        check.adapterStatus(adapter, vault, swapRouter02, poolManager);
        SiliconMainnetOpen.Status memory st = check.status(vault, owner);
        assertFalse(st.accepted);
        assertFalse(st.feeSource);
        assertFalse(st.priced);
        assertTrue(st.indicesLive);
        for (uint256 id; id < 4; ++id) {
            assertFalse(check.canOpen(st, id));
        }
        assertEq(st.totalCeilingUsd, 0);

        _acceptAll(d);
        StakingFeeSourceStub(staking).setFeeSource(address(d.feeRouter()));
        for (uint256 h; h < 24; ++h) {
            vm.warp(block.timestamp + 1 hours);
            _stampFeeds();
            d.oracle().update();
        }
        st = check.status(vault, owner);
        assertTrue(check.adapterStatus(adapter, vault, poolManager, swapRouter02), "the target, 24 hours on");
        assertTrue(st.accepted);
        assertTrue(st.feeSource);
        assertTrue(st.priced);
        assertEq(st.observations, 25);
        assertApproxEqAbs(st.kyznUsd, 0.05e18, 1e9);
        assertApproxEqAbs(st.depthUsd, 50_000e18, 1e15);
        uint256 total;
        for (uint256 id; id < 4; ++id) {
            assertApproxEqAbs(st.ceilingUsd[id], 25_000e18, 1e6);
            assertTrue(check.canOpen(st, id), "each ceiling is within the depth");
            total += st.ceilingUsd[id];
        }
        // The four together pass the depth: printed beside it, the owner's decision, not refused.
        assertEq(st.totalCeilingUsd, total);
        assertGt(st.totalCeilingUsd, st.depthUsd);
        check.report(vault, owner);

        // An index too old to liquidate on, or priced at zero, stops every listing.
        stocks[6].set(700e8, block.timestamp - 96 hours - 1);
        st = check.status(vault, owner);
        assertFalse(st.freshForLiquidation[3]);
        assertFalse(st.indicesLive);
        for (uint256 id; id < 4; ++id) {
            assertFalse(check.canOpen(st, id));
        }
        check.report(vault, owner);
        stocks[6].set(700e8, block.timestamp + 1); // dated in the future: unreadable, price zero
        st = check.status(vault, owner);
        assertEq(st.indexPrice[3], 0);
        assertFalse(st.indicesLive);

        // An open market counts in the sum and is not listed again.
        stocks[6].set(700e8, block.timestamp);
        vm.prank(owner);
        vault.openMarket(0);
        st = check.status(vault, owner);
        assertTrue(st.open[0]);
        assertFalse(check.canOpen(st, 0));
        assertEq(st.totalCeilingUsd, total);
    }

    // ---------------------------------------------------------------- the recorder

    /// deployments/4663.json is written only with the deployment receipt's block; another file
    /// (the fork test's scratch copies) may go without it.
    function test_the_recorder_needs_the_receipt_block_for_the_mainnet_file() public {
        RecordSiliconMainnet recorder = new RecordSiliconMainnet();
        address nothing = makeAddr("nothing");
        vm.expectRevert(abi.encodeWithSelector(RecordSiliconMainnet.NotMainnet.selector, block.chainid));
        recorder.record(nothing, 1, "deployments/.scratch.json");

        vm.chainId(RH.CHAIN_ID);
        string[3] memory mainnetFiles = ["deployments/4663.json", "./deployments/4663.json", "4663.json"];
        for (uint256 i; i < mainnetFiles.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(RecordSiliconMainnet.ReceiptBlockRequired.selector, mainnetFiles[i]));
            recorder.record(nothing, 0, mainnetFiles[i]);
        }
        // Other files pass that check and stop at the address, which has no code.
        string[2] memory others = ["deployments/.silicon-record-run-4663.json", "deployments/46630.json"];
        for (uint256 i; i < others.length; ++i) {
            vm.expectRevert(abi.encodeWithSelector(RecordSiliconMainnet.NoCode.selector, "SiliconMainnet", nothing));
            recorder.record(nothing, 0, others[i]);
        }
        vm.expectRevert(abi.encodeWithSelector(RecordSiliconMainnet.NoCode.selector, "SiliconMainnet", nothing));
        recorder.record(nothing, 1, "deployments/4663.json");
    }

    // ---------------------------------------------------------------- helpers

    /// SiliconMainnet's terms on the stand-ins.
    function _setup() internal view returns (SiliconDeployment.Setup memory s) {
        s.owner = owner;
        s.kyzn = address(kyzn);
        s.usdg = address(usdg);
        s.pair = pair;
        s.ethUsdFeed = address(ethUsd);
        s.weth = address(weth);
        s.oracleShortWindow = Terms.ORACLE_SHORT_WINDOW;
        s.oracleLongWindow = Terms.ORACLE_LONG_WINDOW;
        s.reserve = reserve;
        s.staking = staking;
        s.keeper = keeper;
        s.v4PoolManager = poolManager;
        s.swapRouter02 = swapRouter02;
        s.reserveShareBps = Terms.RESERVE_SHARE_BPS;
        s.levels = SiliconDeployment.Levels({
            mintFeeBps: Terms.MINT_FEE_BPS,
            borrowFeeBpsPerYear: Terms.BORROW_FEE_BPS_PER_YEAR,
            liquidationPenaltyBps: Terms.LIQUIDATION_PENALTY_BPS,
            debtCeilingUsd: Terms.DEBT_CEILING_USD,
            minDebtUsd: Terms.MIN_DEBT_USD,
            auctionDuration: Terms.AUCTION_DURATION,
            auctionStartPremiumBps: Terms.AUCTION_START_PREMIUM_BPS,
            auctionFloorBps: Terms.AUCTION_FLOOR_BPS
        });
        s.closedDays = Terms.closedDays();
        s.earlyCloseDays = Terms.earlyCloseDays();
        uint256[2][4] memory baskets = [[uint256(0), 1], [uint256(2), 3], [uint256(4), 5], [uint256(6), 7]];
        for (uint256 id; id < 4; ++id) {
            s.indices[id] = Terms.index(id);
            address[] memory standIns = new address[](id == 3 ? 1 : 2);
            for (uint256 j; j < standIns.length; ++j) {
                standIns[j] = address(stocks[baskets[id][j]]);
            }
            s.indices[id].feeds = standIns;
        }
    }

    function _acceptAll(SiliconDeployment d) internal {
        StockIndexFeed[4] memory feeds = d.feeds();
        address[7] memory owned = [
            address(d.calendar()),
            address(d.vault()),
            address(d.feeRouter()),
            address(feeds[0]),
            address(feeds[1]),
            address(feeds[2]),
            address(feeds[3])
        ];
        for (uint256 i; i < owned.length; ++i) {
            vm.prank(owner);
            Ownable2Step(owned[i]).acceptOwnership();
        }
    }

    /// Every feed's answer dated now.
    function _stampFeeds() internal {
        ethUsd.set(ethUsd.answer(), block.timestamp);
        for (uint256 i; i < stocks.length; ++i) {
            stocks[i].set(stocks[i].answer(), block.timestamp);
        }
    }

    function _assertBasket(uint256 id, address first, address second) internal pure {
        address[] memory b = Terms.index(id).feeds;
        assertEq(b.length, 2);
        assertEq(b[0], first);
        assertEq(b[1], second);
    }

    function _addresses(SiliconSynth[4] memory list) internal pure returns (address[4] memory out) {
        for (uint256 i; i < 4; ++i) {
            out[i] = address(list[i]);
        }
    }

    function _feedAddresses(StockIndexFeed[4] memory list) internal pure returns (address[4] memory out) {
        for (uint256 i; i < 4; ++i) {
            out[i] = address(list[i]);
        }
    }
}
