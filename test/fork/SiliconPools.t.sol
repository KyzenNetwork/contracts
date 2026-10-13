// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test} from "forge-std/Test.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {MarketCalendar} from "../../src/silicon/MarketCalendar.sol";
import {SiliconFeeRouter} from "../../src/silicon/SiliconFeeRouter.sol";
import {SiliconSwapAdapter} from "../../src/silicon/SiliconSwapAdapter.sol";
import {StockIndexFeed} from "../../src/silicon/StockIndexFeed.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IV3SwapRouter02} from "../../src/silicon/interfaces/ISwapVenues.sol";
import {IMarketCalendar} from "../../src/silicon/interfaces/IMarketCalendar.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";
import {SiliconPools} from "../../script/SiliconPools.s.sol";
import {SiliconPoolSeed as Seed} from "../../script/lib/SiliconPoolSeed.sol";
import {V4PoolMath as M} from "../../script/lib/V4PoolMath.sol";
import {V4PriceMover} from "../../script/lib/V4PriceMover.sol";
import {
    IPermit2,
    IV4PoolManager,
    IV4PositionManager,
    IV4Quoter,
    IV4StateView,
    IV4UnlockCallback,
    PoolKey,
    QuoteExactSingleParams,
    SwapParams
} from "../../script/interfaces/IUniswapV4.sol";
import {MockSiliconFeed, MockToken} from "../silicon/mocks/SiliconMocks.sol";

/// Uniswap v3 SwapRouter02's single-pool exact input (it pulls the input by ERC-20 allowance).
interface ISwapRouter02Single {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}

/// Uniswap v3 QuoterV2's single-pool quote.
interface IQuoterV2SinglePools {
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

/// Swaps an exact input through a v4 pool straight on the PoolManager: pays the input from the
/// caller (who approved this contract) and sends the output to the caller.
contract V4ExactInSwapper is IV4UnlockCallback {
    IV4PoolManager internal constant PM = IV4PoolManager(RH.UNISWAP_V4_POOL_MANAGER);

    function swap(PoolKey memory key, bool zeroForOne, uint256 amountIn) external returns (uint256 amountOut) {
        return abi.decode(PM.unlock(abi.encode(msg.sender, key, zeroForOne, amountIn)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(PM), "not the PoolManager");
        (address payer, PoolKey memory key, bool zeroForOne, uint256 amountIn) =
            abi.decode(data, (address, PoolKey, bool, uint256));
        uint160 limit = zeroForOne ? M.MIN_SQRT_PRICE + 1 : M.MAX_SQRT_PRICE - 1;
        int256 delta = PM.swap(key, SwapParams(zeroForOne, -int256(amountIn), limit), "");
        // BalanceDelta: amount0 in the upper 128 bits, amount1 in the lower.
        int128 amount0 = int128(delta >> 128);
        int128 amount1 = int128(delta);
        (address tokenIn, address tokenOut) =
            zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        (int128 paid, int128 received) = zeroForOne ? (amount0, amount1) : (amount1, amount0);
        PM.sync(tokenIn);
        require(IERC20(tokenIn).transferFrom(payer, address(PM), uint256(uint128(-paid))), "pay");
        PM.settle();
        PM.take(tokenOut, payer, uint256(uint128(received)));
        return abi.encode(uint256(uint128(received)));
    }
}

/// The Silicon pool script (script/SiliconPools.s.sol, lib/SiliconPoolSeed.sol) on a fork of
/// Robinhood Chain mainnet, against the real Uniswap v4 PoolManager, PositionManager, StateView,
/// V4Quoter, Permit2 and USDG. The four synths are plain 18-decimal ERC-20 stand-ins placed at
/// addresses on both sides of USDG's, so both token orders are seeded; the owner is the owner
/// wallet, its USDG dealt on the fork. Nothing is sent to the chain. Skipped unless
/// ROBINHOOD_RPC_URL names a Robinhood Chain mainnet RPC; the public RPC blocks a fork's burst of
/// requests, so point it at a local forwarder that sends them one at a time:
///   ROBINHOOD_RPC_URL=http://127.0.0.1:8552 forge test --match-path test/fork/SiliconPools.t.sol -vv
contract SiliconPoolsForkTest is Test {
    /// The owner wallet (deployments/4663.json, "deployer").
    address internal constant OWNER = 0x965200078d41c1B91CED2f842106662d8bDdd16e;
    uint256 internal constant MARKETS = 4;
    /// One USDG base unit per synth base unit is this USD price (18 decimals): 10^(18 + 18 - 6).
    uint256 internal constant SCALE = 1e30;
    /// The recommended settings, as the script defaults to them.
    uint24 internal constant FEE = 3000;
    int24 internal constant SPACING = 60;
    bytes4 internal constant MAXIMUM_AMOUNT_EXCEEDED = bytes4(keccak256("MaximumAmountExceeded(uint128,uint128)"));

    SiliconPools internal script;
    V4ExactInSwapper internal swapper;
    IV4StateView internal stateView = IV4StateView(RH.UNISWAP_V4_STATE_VIEW);
    IV4PositionManager internal posm = IV4PositionManager(RH.UNISWAP_V4_POSITION_MANAGER);
    IV4Quoter internal quoter = IV4Quoter(RH.UNISWAP_V4_QUOTER);
    address internal trader = makeAddr("trader");
    /// The stand-ins: kDESIGN and kFAB sort below USDG (synth is currency0), kMEMORY and kEQUIP
    /// above it (synth is currency1).
    address[MARKETS] internal synths;

    function setUp() public {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true, "ROBINHOOD_RPC_URL is not set");
        vm.createSelectFork(url);
        assertEq(block.chainid, RH.CHAIN_ID, "the fork is not Robinhood Chain mainnet");

        script = new SiliconPools();
        swapper = new V4ExactInSwapper();
        uint16[MARKETS] memory prefix = [0x0de5, 0xae30, 0x0fab, 0xe001];
        for (uint256 i; i < MARKETS; ++i) {
            synths[i] = address(uint160(uint256(prefix[i]) << 144) + 1);
            deployCodeTo("SiliconMocks.sol:MockToken", abi.encode(script.symbolAt(i), uint8(18)), synths[i]);
        }
        assertLt(uint160(synths[0]), uint160(RH.USDG));
        assertGt(uint160(synths[1]), uint160(RH.USDG));
        assertLt(uint160(synths[2]), uint160(RH.USDG));
        assertGt(uint160(synths[3]), uint160(RH.USDG));
    }

    // ---------------------------------------------------------------- the deployed contracts

    /// The v4 addresses the script uses are wired to each other on chain, and USDG is 6 decimals.
    function test_the_v4_deployment_reads_back() public view {
        assertEq(posm.poolManager(), RH.UNISWAP_V4_POOL_MANAGER);
        assertEq(posm.permit2(), RH.PERMIT2);
        assertGt(RH.UNISWAP_V4_POOL_MANAGER.code.length, 0);
        assertGt(RH.UNISWAP_V4_STATE_VIEW.code.length, 0);
        assertGt(RH.UNISWAP_V4_QUOTER.code.length, 0);
        assertEq(MockToken(RH.USDG).decimals(), 6);
        assertEq(MockToken(RH.USDG).symbol(), "USDG");
    }

    // ---------------------------------------------------------------- refusals

    /// deployments/4663.json has no Silicon markets yet: the script refuses before reading
    /// anything else.
    function test_refuses_until_the_silicon_deployment_is_recorded() public {
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.NoSiliconMarkets.selector, "deployments/4663.json"));
        vm.prank(OWNER);
        script.run();
    }

    /// Only the owner wallet (SiliconMainnetTerms.OWNER) may run it or seed through it.
    function test_refuses_any_broadcaster_but_the_owner_wallet() public {
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.NotOwnerWallet.selector, stranger, OWNER));
        vm.prank(stranger);
        script.run();

        SiliconPools.Market[MARKETS] memory list = _list(_mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]));
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.NotOwnerWallet.selector, stranger, OWNER));
        script.seed(stranger, list, _settings(0), false);
    }

    function test_refuses_a_record_without_one_of_the_four_markets() public {
        address[MARKETS] memory feeds;
        string memory json = _json(3, feeds);
        vm.expectRevert(
            abi.encodeWithSelector(SiliconPools.MarketNotRecorded.selector, "kEQUIP", "deployments/4663.json")
        );
        script.markets(json);
    }

    function test_refuses_a_record_whose_usdg_is_not_usdg() public {
        address[MARKETS] memory feeds;
        address other = makeAddr("other dollar");
        string memory json = vm.replace(_json(MARKETS, feeds), vm.toString(RH.USDG), vm.toString(other));
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.WrongUsdg.selector, other, RH.USDG));
        script.markets(json);
    }

    function test_reads_the_markets_and_the_amounts_from_the_environment() public {
        address[MARKETS] memory feeds = _mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]);
        SiliconPools.Market[MARKETS] memory list = script.markets(_json(MARKETS, feeds));
        for (uint256 i; i < MARKETS; ++i) {
            assertEq(list[i].symbol, script.symbolAt(i));
            assertEq(list[i].synth, synths[i]);
            assertEq(list[i].feed, feeds[i]);
        }
        vm.setEnv("KYZEN_POOL_KFAB_SYNTH", "250000000000000000000");
        vm.setEnv("KYZEN_POOL_KFAB_USDG", "25000000000");
        list = script.amountsFromEnv(list);
        assertEq(list[2].synthAmount, 250e18);
        assertEq(list[2].usdgAmount, 25_000e6);
        assertEq(list[0].synthAmount, 0);
        assertEq(list[0].usdgAmount, 0);
    }

    /// The fee, the tick spacing, the range and the mode have no default: each must be set. (Only this test
    /// reads or sets them, so the process-wide environment does not race other tests.)
    function test_requires_the_fee_the_tick_spacing_and_the_range() public {
        if (!vm.envExists("KYZEN_POOL_FEE")) {
            vm.expectRevert(abi.encodeWithSelector(SiliconPools.MissingSetting.selector, "KYZEN_POOL_FEE"));
            script.settingsFromEnv();
        }
        vm.setEnv("KYZEN_POOL_FEE", "3000");
        if (!vm.envExists("KYZEN_POOL_TICK_SPACING")) {
            vm.expectRevert(abi.encodeWithSelector(SiliconPools.MissingSetting.selector, "KYZEN_POOL_TICK_SPACING"));
            script.settingsFromEnv();
        }
        vm.setEnv("KYZEN_POOL_TICK_SPACING", "60");
        if (!vm.envExists("KYZEN_POOL_RANGE_BPS")) {
            vm.expectRevert(abi.encodeWithSelector(SiliconPools.MissingSetting.selector, "KYZEN_POOL_RANGE_BPS"));
            script.settingsFromEnv();
        }
        vm.setEnv("KYZEN_POOL_RANGE_BPS", "0");
        Seed.Settings memory s = script.settingsFromEnv();
        assertEq(s.fee, 3000);
        assertEq(s.tickSpacing, 60);
        assertEq(s.rangeBps, 0);
        vm.setEnv("KYZEN_POOL_RANGE_BPS", "10000");
        vm.expectRevert(abi.encodeWithSelector(Seed.BadSettings.selector, 3000, 60, 10_000));
        script.settingsFromEnv();
        vm.setEnv("KYZEN_POOL_TICK_SPACING", "0");
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.BadSetting.selector, "KYZEN_POOL_TICK_SPACING"));
        script.settingsFromEnv();

        // The mode is required too: bid or two-sided.
        if (!vm.envExists("KYZEN_POOL_MODE")) {
            vm.expectRevert(abi.encodeWithSelector(SiliconPools.MissingSetting.selector, "KYZEN_POOL_MODE"));
            script.bidFromEnv();
        }
        vm.setEnv("KYZEN_POOL_MODE", "bid");
        assertTrue(script.bidFromEnv());
        vm.setEnv("KYZEN_POOL_MODE", "two-sided");
        assertFalse(script.bidFromEnv());
        vm.setEnv("KYZEN_POOL_MODE", "both");
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.BadSetting.selector, "KYZEN_POOL_MODE"));
        script.bidFromEnv();
    }

    function test_refuses_a_market_with_one_amount() public {
        SiliconPools.Market[MARKETS] memory list = _list(_mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]));
        list[1].usdgAmount = 0;
        _fundOwner(1_000e18, 1_000_000e6);
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.OneAmountMissing.selector, "kMEMORY"));
        script.seed(OWNER, list, _settings(0), false);
    }

    function test_refuses_an_index_price_the_vault_could_not_liquidate_on() public {
        address[MARKETS] memory feeds = _mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]);
        MockSiliconFeed(feeds[2]).setFreshForLiquidation(false);
        SiliconPools.Market[MARKETS] memory list = _list(feeds);
        _fundOwner(1_000e18, 1_000_000e6);
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.StaleIndexPrice.selector, "kFAB", block.timestamp));
        script.seed(OWNER, list, _settings(0), false);
    }

    /// Outside the mint window (here a component over 24 hours old) the index price is refused
    /// unless KYZEN_POOL_ALLOW_STALE=1, which still never goes below the liquidation level.
    function test_refuses_an_index_outside_the_mint_window_unless_allowed() public {
        address[MARKETS] memory feeds = _mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]);
        uint256 lastClose = block.timestamp - 37 hours; // the mocks are fresh for 36 hours
        MockSiliconFeed(feeds[1]).setUpdatedAt(lastClose);
        SiliconPools.Market[MARKETS] memory list = _list(feeds);
        list[2].synthAmount = 0;
        list[2].usdgAmount = 0;
        list[3].synthAmount = 0;
        list[3].usdgAmount = 0;
        _fundOwner(1_000e18, 1_000_000e6);
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.IndexNotFresh.selector, "kMEMORY", lastClose));
        script.seed(OWNER, list, _settings(0), false);

        (Seed.Plan[] memory plans,) = script.seed(OWNER, list, _settings(0), true);
        assertEq(plans.length, 2);

        vm.setEnv("KYZEN_POOL_ALLOW_STALE", "2");
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.BadSetting.selector, "KYZEN_POOL_ALLOW_STALE"));
        script.allowStaleFromEnv();
        vm.setEnv("KYZEN_POOL_ALLOW_STALE", "1");
        assertTrue(script.allowStaleFromEnv());
        vm.setEnv("KYZEN_POOL_ALLOW_STALE", "0");
        assertFalse(script.allowStaleFromEnv());
    }

    function test_refuses_a_synth_whose_symbol_is_not_the_markets() public {
        SiliconPools.Market[MARKETS] memory list = _list(_mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]));
        (list[0].synth, list[1].synth) = (list[1].synth, list[0].synth);
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.WrongSymbol.selector, synths[1], "kDESIGN", "kMEMORY"));
        script.seed(OWNER, list, _settings(0), false);
    }

    /// Every balance is checked before anything is sent.
    function test_refuses_when_the_owner_holds_too_little_usdg() public {
        SiliconPools.Market[MARKETS] memory list = _list(_mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]));
        _fundOwner(1_000e18, 1e6);
        // The four positions need about 4 x 10,000 USDG; the owner holds 1.
        vm.expectPartialRevert(SiliconPools.InsufficientBalance.selector);
        script.seed(OWNER, list, _settings(0), false);
    }

    function test_refuses_a_pool_that_already_has_a_price() public {
        SiliconPools.Market[MARKETS] memory list = _list(_mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]));
        Seed.Plan memory p = Seed.plan(synths[0], RH.USDG, 100e18, 1e18, 100e6, _settings(0));
        IV4PoolManager(RH.UNISWAP_V4_POOL_MANAGER).initialize(p.key, p.sqrtPriceX96);
        vm.expectRevert(abi.encodeWithSelector(Seed.PoolExists.selector, p.poolId, p.sqrtPriceX96));
        script.seed(OWNER, list, _settings(0), false);
    }

    /// Someone initialises the pool at another price after the plan was made: the multicall's
    /// initializePool passes over it and the mint reverts on its maxima, so the owner never adds
    /// liquidity at a price other than the index's.
    function test_a_pool_initialised_first_at_another_price_stops_the_mint() public {
        _fundOwner(1_000e18, 100_000e6);
        Seed.Plan memory p = Seed.plan(synths[0], RH.USDG, 100e18, 100e18, 10_000e6, _settings(0));
        uint160 other = M.sqrtPriceForUsd(101e18, p.synthIsCurrency0, SCALE);
        IV4PoolManager(RH.UNISWAP_V4_POOL_MANAGER).initialize(p.key, other);
        vm.expectPartialRevert(MAXIMUM_AMOUNT_EXCEEDED);
        this.seedAs(p, OWNER);

        // One tick below the index price is refused as well.
        Seed.Plan memory q = Seed.plan(synths[1], RH.USDG, 100e18, 100e18, 10_000e6, _settings(0));
        IV4PoolManager(RH.UNISWAP_V4_POOL_MANAGER).initialize(q.key, M.getSqrtPriceAtTick(q.tick - 1));
        vm.expectPartialRevert(MAXIMUM_AMOUNT_EXCEEDED);
        this.seedAs(q, OWNER);
    }

    // ---------------------------------------------------------------- seeding

    /// The four index pools at the prices of four StockIndexFeeds on the real Chainlink feeds (each
    /// index starts at $100 and moves with its basket), seeded by the script from the owner wallet:
    /// each pool's price is the index price within one tick, the owner holds a position NFT with
    /// the pool's whole liquidity, and exactly the planned amounts left the wallet.
    function test_seeds_the_four_index_pools_at_their_feed_prices() public {
        address[MARKETS] memory feeds = _indexFeeds();
        SiliconPools.Market[MARKETS] memory list = script.markets(_json(MARKETS, feeds));
        bool fresh = true;
        for (uint256 i; i < MARKETS; ++i) {
            list[i].synthAmount = 250e18;
            list[i].usdgAmount = 25_000e6;
            fresh = fresh && StockIndexFeed(feeds[i]).isFresh();
        }
        // Run outside the mint window, the real feeds are refused without the override first.
        if (!fresh) {
            _fundOwner(1_000e18, 1_000_000e6);
            vm.expectPartialRevert(SiliconPools.IndexNotFresh.selector);
            script.seed(OWNER, list, _settings(0), false);
        }
        _seedAndCheck(list, _settings(0), !fresh);
    }

    /// Prices far from $100 and both token orders: the same odd price with the synth as currency0
    /// and as currency1, a five-digit price and a five-cent one.
    function test_seeds_at_any_price_in_either_token_order() public {
        address[MARKETS] memory feeds =
            _mockFeeds([uint256(37.123456789012345678e18), 37.123456789012345678e18, 98_765.4321e18, 0.0512e18]);
        SiliconPools.Market[MARKETS] memory list = _list(feeds);
        for (uint256 i; i < MARKETS; ++i) {
            list[i].synthAmount = 1_000e18;
            list[i].usdgAmount = 1_000_000e6;
        }
        _seedAndCheck(list, _settings(0), false);
    }

    /// A range position, plus and minus 20% of the index price, widened to the tick spacing.
    function test_seeds_a_range_position_around_the_price() public {
        address[MARKETS] memory feeds = _mockFeeds([uint256(137.42e18), 137.42e18, 137.42e18, 137.42e18]);
        SiliconPools.Market[MARKETS] memory list = _list(feeds);
        list[2].synthAmount = 0;
        list[2].usdgAmount = 0;
        list[3].synthAmount = 0;
        list[3].usdgAmount = 0;
        (Seed.Plan[] memory plans,) = _seedAndCheck(list, _settings(2_000), false);
        assertEq(plans.length, 2);
        for (uint256 i; i < plans.length; ++i) {
            Seed.Plan memory p = plans[i];
            assertEq(p.tickLower % SPACING, 0);
            assertEq(p.tickUpper % SPACING, 0);
            assertLe(p.tickLower, p.tick);
            assertLt(p.tick, p.tickUpper);
            uint256 a = M.usdForSqrtPrice(M.getSqrtPriceAtTick(p.tickLower), p.synthIsCurrency0, SCALE);
            uint256 b = M.usdForSqrtPrice(M.getSqrtPriceAtTick(p.tickUpper), p.synthIsCurrency0, SCALE);
            (uint256 low, uint256 high) = a < b ? (a, b) : (b, a);
            // At or past 80% and 120% of the price, and no further than one tick spacing past them.
            assertLe(low, 137.42e18 * 8_000 / 10_000);
            assertGe(low, 137.42e18 * 8_000 / 10_000 * 994 / 1000);
            assertGe(high, 137.42e18 * 12_000 / 10_000);
            assertLe(high, 137.42e18 * 12_000 / 10_000 * 1006 / 1000);
        }
    }

    // ---------------------------------------------------------------- USDG-only bids

    /// The owner's seeding (SPEC 3.5): 0.30%, spacing 60, $100 of USDG per pool as a bid from the
    /// index price down 10%, through the script's bid mode, in both token orders (kDESIGN sorts
    /// below USDG, kMEMORY above). Each pool starts at the index price with no liquidity at it; the
    /// position holds only USDG, from the first usable tick below the index price down to 90% of it.
    /// A $10 sale of synth fills at or below the index price; the fee router sells $10 of fee synth
    /// through the swap adapter at a quote within SPEC 3.5's 97% of the Chainlink-implied value; a
    /// buy of synth before any sale finds no synth and returns nothing.
    function test_seeds_usdg_only_bids_below_the_index_price() public {
        uint256[MARKETS] memory prices = [uint256(100e18), 137.42e18, 100e18, 100e18];
        address[MARKETS] memory feeds = _mockFeeds(prices);
        SiliconPools.Market[MARKETS] memory list = _list(feeds);
        for (uint256 i; i < MARKETS; ++i) {
            list[i].synthAmount = 0;
            list[i].usdgAmount = i < 2 ? 100e6 : 0;
        }
        _fundOwner(1_000e18, 1_000e6);
        Seed.Settings memory s = Seed.Settings({fee: FEE, tickSpacing: SPACING, rangeBps: 1_000});

        // A synth amount has no place in a bid.
        list[0].synthAmount = 1e18;
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.SynthAmountInBidMode.selector, "kDESIGN"));
        script.seedBids(OWNER, list, s, false);
        list[0].synthAmount = 0;

        uint256 usdgBefore = IERC20(RH.USDG).balanceOf(OWNER);
        (Seed.Plan[] memory plans, uint256[] memory ids) = script.seedBids(OWNER, list, s, false);
        assertEq(plans.length, 2);
        assertTrue(plans[0].synthIsCurrency0, "kDESIGN is currency0");
        assertFalse(plans[1].synthIsCurrency0, "kMEMORY is currency1");
        uint256 usdgSpent;
        for (uint256 k; k < 2; ++k) {
            usdgSpent += _assertBid(plans[k], ids[k], prices[k]);
        }
        assertEq(usdgBefore - IERC20(RH.USDG).balanceOf(OWNER), usdgSpent, "only the bids' USDG left the wallet");
        for (uint256 k; k < 2; ++k) {
            assertEq(IERC20(plans[k].synth).balanceOf(OWNER), 1_000e18, "no synth taken");
            assertEq(IERC20(plans[k].synth).allowance(OWNER, RH.PERMIT2), 0, "synth never approved");
        }

        // Before any sale the bid holds no synth: a buy finds nothing (and only moves the empty
        // pool's price); a sale then still fills inside the bid, at or below the index price.
        _buyFromBid(plans[0]);
        _sellIntoBid(plans[0], prices[0]);
        _convertThroughBid(plans[1], prices[1]);
    }

    /// The pool starts at the index price; the position is the owner's, holds only USDG (the pool
    /// has no liquidity at its price) and spans 90% of the index price up to the first usable tick
    /// below it. Returns the USDG it took.
    function _assertBid(Seed.Plan memory p, uint256 tokenId, uint256 price) internal view returns (uint256 usdgIn) {
        (uint160 sqrtPriceX96, int24 tick,, uint24 lpFee) = stateView.getSlot0(p.poolId);
        assertEq(sqrtPriceX96, M.sqrtPriceForUsd(price, p.synthIsCurrency0, SCALE), "initialised at the index price");
        assertEq(lpFee, FEE);
        assertEq(stateView.getLiquidity(p.poolId), 0, "no liquidity at the index price");
        assertGt(p.liquidity, 0);
        assertEq(posm.getPositionLiquidity(tokenId), p.liquidity, "position liquidity");
        assertEq(posm.ownerOf(tokenId), OWNER, "position owner");
        uint256 synthIn;
        (synthIn, usdgIn) = Seed.amounts(p);
        assertEq(synthIn, 0, "the bid holds no synth");
        assertLe(usdgIn, 100e6);
        assertGe(usdgIn, 100e6 * 9_999 / 10_000, "the bid holds the $100");
        // On the USDG side of the pool's tick, for either token order.
        if (p.synthIsCurrency0) assertLe(p.tickUpper, tick, "below the price");
        else assertLt(tick, p.tickLower, "above the pool tick (below the synth price)");
        assertEq(p.tickLower % SPACING, 0);
        assertEq(p.tickUpper % SPACING, 0);
        uint256 a = M.usdForSqrtPrice(M.getSqrtPriceAtTick(p.tickLower), p.synthIsCurrency0, SCALE);
        uint256 b = M.usdForSqrtPrice(M.getSqrtPriceAtTick(p.tickUpper), p.synthIsCurrency0, SCALE);
        (uint256 low, uint256 high) = a < b ? (a, b) : (b, a);
        // The top is the first usable tick below the index price (within one spacing of it), the
        // bottom 90% of it, widened by at most one spacing (60 ticks, about 0.6%).
        assertLt(high, price, "the top is below the index price");
        assertGe(high, price * 9_939 / 10_000, "the top is within one spacing of it");
        assertLe(low, price * 9 / 10, "the bottom reaches 90%");
        assertGe(low, price * 9 / 10 * 9_939 / 10_000, "and no further than one spacing past it");
    }

    /// A $10 sale of synth into the bid fills at or below the index price. Returns the fill price.
    function _sellIntoBid(Seed.Plan memory p, uint256 price) internal returns (uint256 fillPrice) {
        uint256 synthIn = 10e18 * 1e18 / price;
        MockToken(p.synth).mint(trader, synthIn);
        vm.prank(trader);
        IERC20(p.synth).approve(address(swapper), type(uint256).max);
        vm.prank(trader);
        uint256 usdgOut = swapper.swap(p.key, p.synthIsCurrency0, synthIn);
        fillPrice = usdgOut * 1e12 * 1e18 / synthIn;
        assertGt(usdgOut, 0, "the bid pays USDG");
        assertLe(fillPrice, price, "at or below the index price");
        assertGe(fillPrice, price * 9 / 10 * 997 / 1000, "within the bid");
        console2.log("$10 sale into the bid: USDG out, fill price (1e18)", usdgOut, fillPrice);
    }

    /// The fee router sells $10 of fee synth through the swap adapter into the bid: the quote is
    /// at least 97% of the value the index price and Chainlink ETH/USD imply, and minOut is the
    /// quote less 0.5% (SPEC 3.5).
    function _convertThroughBid(Seed.Plan memory p, uint256 price) internal {
        SiliconSwapAdapter adapter = new SiliconSwapAdapter(
            IV4PoolManager(RH.UNISWAP_V4_POOL_MANAGER), IV3SwapRouter02(RH.UNISWAP_V3_SWAP_ROUTER_02), RH.WETH, RH.USDG
        );
        SiliconFeeRouter router = new SiliconFeeRouter(IWETH(RH.WETH));
        address keeper = makeAddr("keeper");
        router.setKeeper(keeper);
        router.queueTarget(address(adapter), true);
        vm.warp(block.timestamp + 24 hours);

        uint256 amount = 10e18 * 1e18 / price;
        MockToken(p.synth).mint(address(router), amount);
        (uint256 usdgQuoted,) =
            quoter.quoteExactInputSingle(QuoteExactSingleParams(p.key, p.synthIsCurrency0, uint128(amount), ""));
        (uint256 wethQuoted,,,) = IQuoterV2SinglePools(RH.UNISWAP_V3_QUOTER_V2)
            .quoteExactInputSingle(
                IQuoterV2SinglePools.QuoteExactInputSingleParams(RH.USDG, RH.WETH, usdgQuoted, 100, 0)
            );
        (, int256 ethUsd,,,) = IAggregatorV3(RH.ETH_USD_FEED).latestRoundData();
        uint256 implied = amount * price / (uint256(ethUsd) * 1e10);
        assertGe(wethQuoted * 100, implied * 97, "the quote meets 97% of the Chainlink-implied value");

        bytes memory data = abi.encodeCall(SiliconSwapAdapter.sellSynth, (p.key, amount, uint24(100)));
        vm.prank(keeper);
        uint256 received = router.convert(p.synth, address(adapter), data, amount, wethQuoted * 9_950 / 10_000);
        assertEq(received, wethQuoted, "the quoted WETH");
        assertEq(IERC20(p.synth).balanceOf(address(router)), 0, "all sold into the bid");
        console2.log(
            "$10 of fee synth through the adapter: WETH, implied, bps", received, implied, received * 10_000 / implied
        );
    }

    /// A buy of synth with USDG finds no synth in the pool: it fails or returns nothing, and takes
    /// no USDG.
    function _buyFromBid(Seed.Plan memory p) internal {
        deal(RH.USDG, trader, 10e6);
        vm.prank(trader);
        IERC20(RH.USDG).approve(address(swapper), type(uint256).max);
        uint256 synthBefore = IERC20(p.synth).balanceOf(trader);
        vm.prank(trader);
        try swapper.swap(p.key, !p.synthIsCurrency0, 10e6) returns (uint256 out) {
            assertEq(out, 0, "no synth to buy");
        } catch {}
        assertEq(IERC20(p.synth).balanceOf(trader), synthBefore, "no synth received");
        assertEq(IERC20(RH.USDG).balanceOf(trader), 10e6, "no USDG taken");
    }

    // ---------------------------------------------------------------- re-placing a bid

    /// Both indices rise 5% after their $100 bids were seeded (kDESIGN's bid partly filled by a
    /// seller first). Re-placing each one through the script: the old NFT is left empty and the
    /// owner's; everything it held, the synth bought and the fees included, comes back to the owner
    /// wallet; the pool's price is moved to the new index price for free; and the new bid, with all
    /// the USDG that came back, sits from just below the new price down 10%, where a $10 sale now
    /// fills. Refused for another market's position and for any wallet but the owner's.
    function test_replaces_a_bid_after_the_index_rises() public {
        address[MARKETS] memory feeds = _mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]);
        SiliconPools.Market[MARKETS] memory list = _list(feeds);
        for (uint256 i; i < MARKETS; ++i) {
            list[i].synthAmount = 0;
            list[i].usdgAmount = i < 2 ? 100e6 : 0;
        }
        _fundOwner(1_000e18, 1_000e6);
        Seed.Settings memory s = Seed.Settings({fee: FEE, tickSpacing: SPACING, rangeBps: 1_000});
        (Seed.Plan[] memory plans, uint256[] memory ids) = script.seedBids(OWNER, list, s, false);
        _sellIntoBid(plans[0], 100e18);

        // The mover never trades: with the kMEMORY bid in the way it refuses to move.
        V4PriceMover mover = new V4PriceMover(IV4PoolManager(RH.UNISWAP_V4_POOL_MANAGER));
        vm.expectPartialRevert(V4PriceMover.LiquidityInTheWay.selector);
        mover.moveTo(plans[1].key, false, M.getSqrtPriceAtTick(plans[1].tickUpper));

        MockSiliconFeed(feeds[0]).set(105e18);
        MockSiliconFeed(feeds[1]).set(105e18);

        vm.expectRevert(abi.encodeWithSelector(SiliconPools.WrongPosition.selector, ids[1]));
        script.replaceBid(OWNER, list[0], s, ids[1], false);
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.NotOwnerWallet.selector, stranger, OWNER));
        script.replaceBid(stranger, list[0], s, ids[0], false);

        _assertReplaced(list[0], ids[0], s, true);
        _assertReplaced(list[1], ids[1], s, false);
    }

    /// replace(string) itself: the owner wallet only, and nothing until the Silicon deployment is
    /// recorded.
    function test_replace_refuses_until_recorded_and_for_other_wallets() public {
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.NotOwnerWallet.selector, address(this), OWNER));
        script.replace("kDESIGN");
        vm.expectRevert(abi.encodeWithSelector(SiliconPools.NoSiliconMarkets.selector, "deployments/4663.json"));
        vm.prank(OWNER);
        script.replace("kDESIGN");
    }

    function _assertReplaced(SiliconPools.Market memory m, uint256 oldId, Seed.Settings memory s, bool filled)
        internal
    {
        uint256 synthBefore = IERC20(m.synth).balanceOf(OWNER);
        (Seed.Plan memory p, SiliconPools.Replaced memory r) = script.replaceBid(OWNER, m, s, oldId, false);

        assertEq(posm.getPositionLiquidity(oldId), 0, "the old NFT has no liquidity");
        assertEq(posm.ownerOf(oldId), OWNER, "and is still the owner's");
        assertEq(IERC20(m.synth).balanceOf(OWNER) - synthBefore, r.synthBack, "synth back to the owner wallet");
        if (filled) {
            assertGt(r.synthBack, 0, "the synth the bid bought");
            assertLt(r.usdgBack, 100e6, "less the USDG the seller took");
        } else {
            assertEq(r.synthBack, 0);
            assertGe(r.usdgBack, 100e6 * 9_999 / 10_000, "the whole bid");
        }

        assertTrue(r.mover != address(0), "the pool's price was moved");
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(p.poolId);
        assertEq(sqrtPriceX96, M.sqrtPriceForUsd(105e18, p.synthIsCurrency0, SCALE), "the pool at the new index price");
        assertEq(stateView.getLiquidity(p.poolId), 0, "the new bid sits beside the price");
        assertGt(p.liquidity, 0);
        assertEq(posm.getPositionLiquidity(r.newTokenId), p.liquidity, "the new position");
        assertEq(posm.ownerOf(r.newTokenId), OWNER);
        (uint256 synthIn, uint256 usdgIn) = Seed.amounts(p);
        assertEq(synthIn, 0, "USDG only");
        assertLe(usdgIn, r.usdgBack);
        assertGe(usdgIn, r.usdgBack * 9_999 / 10_000, "all the USDG that came back");

        uint256 a = M.usdForSqrtPrice(M.getSqrtPriceAtTick(p.tickLower), p.synthIsCurrency0, SCALE);
        uint256 b = M.usdForSqrtPrice(M.getSqrtPriceAtTick(p.tickUpper), p.synthIsCurrency0, SCALE);
        (uint256 low, uint256 high) = a < b ? (a, b) : (b, a);
        assertLt(high, 105e18, "the top is below the new index price");
        assertGe(high, 105e18 * 9_939 / 10_000, "within one spacing of it");
        assertLe(low, 94.5e18, "the bottom reaches 90% of it");
        assertGe(low, 94.5e18 * 9_939 / 10_000);

        uint256 fill = _sellIntoBid(p, 105e18);
        assertGt(fill, 100e18, "a sale now fills above the old index price");
        console2.log(m.symbol, "re-placed; a $10 sale now fills at (1e18)", fill);
        console2.log("  USDG back, synth back", r.usdgBack, r.synthBack);
    }

    // ---------------------------------------------------------------- swap fees

    /// The runbook's swap-fee procedure (docs/superpowers/silicon-mainnet-runbook.md, "Pool swap
    /// fees"): after trades, the owner collects the position's fees straight to the fee router with
    /// DECREASE_LIQUIDITY of 0 and TAKE_PAIR, which leaves the liquidity as it was; the router's
    /// keeper then converts the USDG to WETH through SwapRouter02 once that target's 24 hours have
    /// passed. (The synth has no such target: see the runbook.)
    function test_the_owner_collects_the_swap_fees_to_the_fee_router() public {
        SiliconPools.Market[MARKETS] memory list = _list(_mockFeeds([uint256(100e18), 100e18, 100e18, 100e18]));
        for (uint256 i = 1; i < MARKETS; ++i) {
            list[i].synthAmount = 0;
            list[i].usdgAmount = 0;
        }
        _fundOwner(1_000e18, 1_000_000e6);
        (Seed.Plan[] memory plans, uint256[] memory ids) = script.seed(OWNER, list, _settings(0), false);
        Seed.Plan memory p = plans[0];
        (uint256 usdgIn, uint256 synthIn) = _swapBothWays(p);

        SiliconFeeRouter router = new SiliconFeeRouter(IWETH(RH.WETH));
        uint128 liquidity = posm.getPositionLiquidity(ids[0]);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(ids[0], uint256(0), uint128(0), uint128(0), bytes(""));
        params[1] = abi.encode(p.key.currency0, p.key.currency1, address(router));
        bytes memory actions = abi.encodePacked(uint8(0x01), uint8(0x11)); // DECREASE_LIQUIDITY, TAKE_PAIR
        vm.prank(OWNER);
        posm.modifyLiquidities(abi.encode(actions, params), block.timestamp + 30 minutes);

        // The LP fee on each trade's input, 0.30%, less the pool's rounding.
        uint256 usdgFees = IERC20(RH.USDG).balanceOf(address(router));
        uint256 synthFees = IERC20(p.synth).balanceOf(address(router));
        assertApproxEqRel(usdgFees, usdgIn * FEE / 1e6, 1e15, "USDG fees");
        assertApproxEqRel(synthFees, synthIn * FEE / 1e6, 1e15, "synth fees");
        assertEq(posm.getPositionLiquidity(ids[0]), liquidity, "liquidity unchanged");
        assertEq(posm.ownerOf(ids[0]), OWNER, "the NFT stays the owner's");

        address keeper = makeAddr("keeper");
        router.setKeeper(keeper);
        router.queueTarget(RH.UNISWAP_V3_SWAP_ROUTER_02, true);
        assertFalse(router.isTargetAllowed(RH.UNISWAP_V3_SWAP_ROUTER_02), "live before its 24 hours");
        vm.warp(block.timestamp + 24 hours);
        bytes memory data = abi.encodeCall(
            ISwapRouter02Single.exactInputSingle,
            (ISwapRouter02Single.ExactInputSingleParams(RH.USDG, RH.WETH, 100, address(router), usdgFees, 0, 0))
        );
        vm.prank(keeper);
        uint256 received = router.convert(RH.USDG, RH.UNISWAP_V3_SWAP_ROUTER_02, data, usdgFees, 1);
        assertGt(received, 0, "WETH received");
        assertEq(IERC20(RH.USDG).balanceOf(address(router)), 0, "USDG converted");
        assertEq(IERC20(RH.WETH).balanceOf(address(router)), received, "WETH held for distribute()");
    }

    // ---------------------------------------------------------------- helpers

    /// Seeds `list` through the script from the owner wallet, then checks each pool and swaps
    /// through it both ways.
    function _seedAndCheck(SiliconPools.Market[MARKETS] memory list, Seed.Settings memory s, bool allowStale)
        internal
        returns (Seed.Plan[] memory plans, uint256[] memory ids)
    {
        _fundOwner(10_000e18, 5_000_000e6);
        uint256 usdgBefore = IERC20(RH.USDG).balanceOf(OWNER);
        uint256[MARKETS] memory synthBefore;
        for (uint256 i; i < MARKETS; ++i) {
            synthBefore[i] = IERC20(list[i].synth).balanceOf(OWNER);
        }

        (plans, ids) = script.seed(OWNER, list, s, allowStale);

        uint256 usdgSpent;
        uint256 k;
        for (uint256 i; i < MARKETS; ++i) {
            if (list[i].synthAmount == 0) continue;
            usdgSpent += _checkSeeded(list[i], plans[k], ids[k], synthBefore[i], s, k == plans.length - 1);
            ++k;
        }
        assertEq(k, plans.length);
        assertEq(usdgBefore - IERC20(RH.USDG).balanceOf(OWNER), usdgSpent, "USDG taken");
    }

    /// One seeded market: the pool, what left the wallet, the leftover approvals, and a swap each
    /// way. Returns the USDG the mint took.
    function _checkSeeded(
        SiliconPools.Market memory m,
        Seed.Plan memory p,
        uint256 tokenId,
        uint256 synthBefore,
        Seed.Settings memory s,
        bool lastPool
    ) internal returns (uint256 usdgIn) {
        assertEq(p.synth, m.synth);
        (uint256 price,) = MockSiliconFeed(m.feed).latestPrice();
        _assertPool(p, tokenId, price, s);
        uint256 synthIn;
        (synthIn, usdgIn) = Seed.amounts(p);
        assertEq(synthBefore - IERC20(p.synth).balanceOf(OWNER), synthIn, "synth taken");
        assertLe(synthIn, m.synthAmount);
        assertLe(usdgIn, m.usdgAmount);
        // One side binds: it is used to within a part in a million of what was offered.
        assertTrue(
            synthIn * 1e6 >= m.synthAmount * 999_999 || usdgIn * 1e6 >= m.usdgAmount * 999_999, "neither side binds"
        );
        (uint256 synthMax, uint256 usdgMax) = Seed.maxima(p);
        _assertLeftover(p.synth, synthMax - synthIn, synthIn);
        // USDG is approved again for each pool: what is left is the last pool's margin.
        if (lastPool) _assertLeftover(RH.USDG, usdgMax - usdgIn, usdgIn);
        _swapBothWays(p);
        console2.log(m.symbol, "price (USD, 1e18)", price);
        console2.log("  tick, liquidity", vm.toString(p.tick), p.liquidity);
        console2.log("  synth in, USDG in", synthIn, usdgIn);
    }

    /// The pool is at the index price within one tick: the price lies between the prices of the
    /// pool's tick and the next one up. The position is the owner's and holds all of the pool's
    /// liquidity.
    function _assertPool(Seed.Plan memory p, uint256 tokenId, uint256 price, Seed.Settings memory s) internal view {
        (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee) = stateView.getSlot0(p.poolId);
        assertEq(lpFee, s.fee, "lp fee");
        assertEq(protocolFee, 0, "protocol fee");
        assertEq(sqrtPriceX96, M.sqrtPriceForUsd(price, p.synthIsCurrency0, SCALE), "sqrt price");
        assertEq(p.key.hooks, address(0), "hook");
        assertEq(p.key.currency0, p.synthIsCurrency0 ? p.synth : RH.USDG, "currency0");
        assertEq(p.key.currency1, p.synthIsCurrency0 ? RH.USDG : p.synth, "currency1");
        assertLt(uint160(p.key.currency0), uint160(p.key.currency1), "token order");
        assertEq(p.poolId, keccak256(abi.encode(p.key)), "pool id");

        uint256 atTick = M.usdForSqrtPrice(M.getSqrtPriceAtTick(tick), p.synthIsCurrency0, SCALE);
        uint256 atNext = M.usdForSqrtPrice(M.getSqrtPriceAtTick(tick + 1), p.synthIsCurrency0, SCALE);
        (uint256 low, uint256 high) = atTick < atNext ? (atTick, atNext) : (atNext, atTick);
        // Within one tick (rounding of the conversions allowed at the edges).
        assertGe(price, low - low / 1e15, "below the tick");
        assertLe(price, high + high / 1e15, "above the next tick");
        assertApproxEqRel(M.usdForSqrtPrice(sqrtPriceX96, p.synthIsCurrency0, SCALE), price, 1e6, "pool price");

        uint128 liquidity = stateView.getLiquidity(p.poolId);
        assertGt(liquidity, 0, "pool liquidity");
        assertEq(liquidity, p.liquidity, "pool liquidity is the position's");
        assertEq(posm.getPositionLiquidity(tokenId), p.liquidity, "position liquidity");
        assertEq(posm.ownerOf(tokenId), OWNER, "position owner");
        if (s.rangeBps == 0) {
            assertEq(p.tickLower, M.minUsableTick(s.tickSpacing), "full range, lower");
            assertEq(p.tickUpper, M.maxUsableTick(s.tickSpacing), "full range, upper");
        }
    }

    /// A buy of the synth with USDG worth about 1% of the pool's USDG side raises the synth's
    /// price, a sale of what it bought lowers it again; each fills at the V4Quoter's quote and moves
    /// the price as the constant-liquidity formula says.
    function _swapBothWays(Seed.Plan memory p) internal returns (uint256 usdgIn, uint256 bought) {
        (, uint256 usdgSide) = Seed.amounts(p);
        usdgIn = usdgSide / 100;
        deal(RH.USDG, trader, usdgIn);
        vm.prank(trader);
        IERC20(RH.USDG).approve(address(swapper), type(uint256).max);
        vm.prank(trader);
        IERC20(p.synth).approve(address(swapper), type(uint256).max);

        uint256 before = _poolUsd(p);
        bought = _swapAndCheck(p, !p.synthIsCurrency0, usdgIn);
        uint256 afterBuy = _poolUsd(p);
        assertGt(afterBuy, before, "a buy raises the price");
        // The synth bought cost between the prices before and after, less the fee.
        uint256 paidUsd = usdgIn * 1e12 * (1e6 - p.key.fee) / 1e6;
        assertLe(bought * before / 1e18, paidUsd + paidUsd / 1e12, "bought too much");
        assertGe(bought * afterBuy / 1e18 + 1, paidUsd - paidUsd / 1e12, "bought too little");

        _swapAndCheck(p, p.synthIsCurrency0, bought);
        uint256 afterSell = _poolUsd(p);
        assertLt(afterSell, afterBuy, "a sale lowers the price");
        // The sale's fee keeps it from undoing the whole buy: the round trip ends a little above
        // where it started.
        assertGe(afterSell, before, "round trip below the start");
        assertApproxEqRel(afterSell, before, 1e16, "round trip");
    }

    /// Swaps `amountIn` through the pool as the trader; the output is the quote, and the new price
    /// is what one step of the pool's math gives (to a part in a billion: a swap crossing a tick
    /// bitmap word takes two steps).
    function _swapAndCheck(Seed.Plan memory p, bool zeroForOne, uint256 amountIn) internal returns (uint256 out) {
        (uint160 start,, uint24 protocolFee, uint24 lpFee) = stateView.getSlot0(p.poolId);
        uint128 liquidity = stateView.getLiquidity(p.poolId);
        (uint256 quoted,) =
            quoter.quoteExactInputSingle(QuoteExactSingleParams(p.key, zeroForOne, uint128(amountIn), bytes("")));
        vm.prank(trader);
        out = swapper.swap(p.key, zeroForOne, amountIn);
        assertEq(out, quoted, "quote");
        assertGt(out, 0, "output");

        uint256 fee = _swapFee(protocolFee, lpFee, zeroForOne);
        uint256 lessFee = Math.mulDiv(amountIn, 1e6 - fee, 1e6);
        uint256 expected = zeroForOne
            ? Math.mulDiv(
                uint256(liquidity) << 96, start, (uint256(liquidity) << 96) + lessFee * start, Math.Rounding.Ceil
            )
            : start + Math.mulDiv(lessFee, 1 << 96, liquidity);
        (uint160 end,,,) = stateView.getSlot0(p.poolId);
        assertApproxEqRel(end, expected, 1e9, "price after the swap");
        assertTrue(zeroForOne ? end < start : end > start, "price direction");
    }

    /// After the mint, the owner's ERC-20 allowance to Permit2 and Permit2's allowance to the
    /// PositionManager are both exactly the unused margin, at most 1 part per million of what the
    /// mint took plus 1 wei, and Permit2's expires 30 minutes after the run.
    function _assertLeftover(address token, uint256 margin, uint256 used) internal view {
        assertLe(margin, used / 1e6 + 1, "margin");
        assertEq(IERC20(token).allowance(OWNER, RH.PERMIT2), margin, "ERC-20 allowance to Permit2");
        (uint160 amount, uint48 expiration,) = IPermit2(RH.PERMIT2).allowance(OWNER, token, address(posm));
        assertEq(amount, margin, "Permit2 allowance to the PositionManager");
        assertEq(expiration, block.timestamp + 30 minutes, "Permit2 expiry");
    }

    function _swapFee(uint24 protocolFee, uint24 lpFee, bool zeroForOne) internal pure returns (uint256) {
        uint256 p = zeroForOne ? protocolFee & 0xfff : protocolFee >> 12;
        return p == 0 ? lpFee : p + lpFee - p * lpFee / 1e6;
    }

    function _poolUsd(Seed.Plan memory p) internal view returns (uint256) {
        (uint160 sqrtPriceX96,,,) = stateView.getSlot0(p.poolId);
        return M.usdForSqrtPrice(sqrtPriceX96, p.synthIsCurrency0, SCALE);
    }

    function seedAs(Seed.Plan memory p, address owner) external returns (uint256) {
        vm.startPrank(owner);
        uint256 id = Seed.seed(p, owner, block.timestamp + 30 minutes);
        vm.stopPrank();
        return id;
    }

    function _fundOwner(uint256 synthEach, uint256 usdg) internal {
        for (uint256 i; i < MARKETS; ++i) {
            MockToken(synths[i]).mint(OWNER, synthEach);
        }
        deal(RH.USDG, OWNER, usdg);
        assertEq(IERC20(RH.USDG).balanceOf(OWNER), usdg, "USDG dealt");
    }

    function _settings(uint256 rangeBps) internal pure returns (Seed.Settings memory) {
        return Seed.Settings({fee: FEE, tickSpacing: SPACING, rangeBps: rangeBps});
    }

    /// Four StockIndexFeeds on the seven real Chainlink feeds, as the mainnet deployment builds them.
    function _indexFeeds() internal returns (address[MARKETS] memory feeds) {
        MarketCalendar cal = new MarketCalendar(address(this));
        address[7] memory chainlink =
            [RH.NVDA_USD, RH.AMD_USD, RH.MU_USD, RH.SNDK_USD, RH.TSM_USD, RH.INTC_USD, RH.ASML_USD];
        uint256 next;
        for (uint256 s; s < MARKETS; ++s) {
            address[] memory components = new address[](s == 3 ? 1 : 2);
            for (uint256 j; j < components.length; ++j) {
                components[j] = chainlink[next++];
            }
            feeds[s] = address(
                new StockIndexFeed(
                    string.concat(script.symbolAt(s), " / USD"),
                    IMarketCalendar(address(cal)),
                    components,
                    address(this)
                )
            );
        }
    }

    function _mockFeeds(uint256[MARKETS] memory prices) internal returns (address[MARKETS] memory feeds) {
        for (uint256 i; i < MARKETS; ++i) {
            feeds[i] = address(new MockSiliconFeed(prices[i], 36 hours));
        }
    }

    /// The four markets with 100 synth and 10,000 USDG offered to each.
    function _list(address[MARKETS] memory feeds) internal view returns (SiliconPools.Market[MARKETS] memory list) {
        for (uint256 i; i < MARKETS; ++i) {
            list[i] = SiliconPools.Market({
                symbol: script.symbolAt(i), synth: synths[i], feed: feeds[i], synthAmount: 100e18, usdgAmount: 10_000e6
            });
        }
    }

    /// A deployment file with the first `n` markets under "silicon.markets", in reverse order (the
    /// script finds each by its symbol).
    function _json(uint256 n, address[MARKETS] memory feeds) internal view returns (string memory) {
        string memory entries;
        for (uint256 k; k < n; ++k) {
            uint256 i = n - 1 - k;
            entries = string.concat(
                entries,
                k == 0 ? "" : ",",
                '{"symbol":"',
                script.symbolAt(i),
                '","synth":"',
                vm.toString(synths[i]),
                '","feed":"',
                vm.toString(feeds[i]),
                '"}'
            );
        }
        return
            string.concat('{"chainId":4663,"silicon":{"usdg":"', vm.toString(RH.USDG), '","markets":[', entries, "]}}");
    }
}

/// The pool math against v4-core's own fixed points, and its round trips (no fork).
contract V4PoolMathTest is Test {
    function test_fixed_points() public pure {
        assertEq(M.getSqrtPriceAtTick(0), 1 << 96);
        assertEq(M.getSqrtPriceAtTick(M.MIN_TICK), M.MIN_SQRT_PRICE);
        assertEq(M.getSqrtPriceAtTick(M.MAX_TICK), M.MAX_SQRT_PRICE);
        assertEq(M.getTickAtSqrtPrice(M.MIN_SQRT_PRICE), M.MIN_TICK);
        assertEq(M.getTickAtSqrtPrice(M.MAX_SQRT_PRICE - 1), M.MAX_TICK - 1);
        assertEq(M.getTickAtSqrtPrice(1 << 96), 0);
        assertEq(M.minUsableTick(60), -887220);
        assertEq(M.maxUsableTick(60), 887220);
        assertEq(M.floorToSpacing(-61, 60), -120);
        assertEq(M.floorToSpacing(61, 60), 60);
        assertEq(M.ceilToSpacing(-61, 60), -60);
        assertEq(M.ceilToSpacing(61, 60), 120);
        assertEq(M.ceilToSpacing(-60, 60), -60);
    }

    /// Each tick's price maps back to that tick, and one below it to the tick before.
    function testFuzz_tick_round_trip(int24 tick) public pure {
        tick = int24(bound(tick, int256(M.MIN_TICK) + 1, int256(M.MAX_TICK) - 1));
        uint160 sqrtPriceX96 = M.getSqrtPriceAtTick(tick);
        assertEq(M.getTickAtSqrtPrice(sqrtPriceX96), tick);
        assertEq(M.getTickAtSqrtPrice(sqrtPriceX96 - 1), tick - 1);
        assertLt(sqrtPriceX96, M.getSqrtPriceAtTick(tick + 1));
    }

    /// A USD price from a tenth of a cent to a million dollars survives the trip to a pool price
    /// and back, in either token order.
    function testFuzz_usd_round_trip(uint256 usd, bool synthIsCurrency0) public pure {
        usd = bound(usd, 1e15, 1e24);
        uint160 sqrtPriceX96 = M.sqrtPriceForUsd(usd, synthIsCurrency0, 1e30);
        assertApproxEqRel(M.usdForSqrtPrice(sqrtPriceX96, synthIsCurrency0, 1e30), usd, 1e6);
    }
}
