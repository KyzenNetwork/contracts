// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznToken} from "../../../src/KyznToken.sol";
import {IWETH} from "../../../src/interfaces/IWETH.sol";
import {IAggregatorV3} from "../../../src/interfaces/IAggregatorV3.sol";
import {KyznUsdOracle} from "../../../src/silicon/KyznUsdOracle.sol";
import {MarketCalendar} from "../../../src/silicon/MarketCalendar.sol";
import {SiliconFeeRouter} from "../../../src/silicon/SiliconFeeRouter.sol";
import {SiliconSwapAdapter} from "../../../src/silicon/SiliconSwapAdapter.sol";
import {SiliconSynth} from "../../../src/silicon/SiliconSynth.sol";
import {SiliconVault} from "../../../src/silicon/SiliconVault.sol";
import {StockIndexFeed} from "../../../src/silicon/StockIndexFeed.sol";
import {SiliconDeployment, SiliconMainnet, SiliconMainnetTerms as Terms} from "../../../script/SiliconMainnet.sol";
import {RobinhoodChain as RH} from "../../../script/RobinhoodChain.sol";

/// The real $KYZN/WETH pair, as far as these tests use it.
interface ISiliconForkPair {
    function token0() external view returns (address);
    function getReserves() external view returns (uint112, uint112, uint32);
    function totalSupply() external view returns (uint256);
    function mint(address to) external returns (uint256 liquidity);
}

/// ArbSys on a fork: the fork's block number is the chain's own (the precompile itself has no code
/// a fork can run).
contract ForkArbSys {
    function arbBlockNumber() external view returns (uint256) {
        return block.number;
    }
}

/// A call that does nothing, to tell whether forge runs each call as a transaction of its own.
contract SiliconIsolationProbe {
    function ping() external {}
}

/// The Silicon mainnet deployment on a fork of Robinhood Chain mainnet, as the owner wallet sends
/// it, and the steps after it. Skipped unless ROBINHOOD_RPC_URL names a Robinhood Chain mainnet
/// RPC: the public RPC blocks the burst of requests a fork makes, so point it at the local serial
/// forwarder (http://127.0.0.1:8552). The fork is the latest block, made in setUp (the public RPC
/// keeps about twenty minutes of state).
///
/// What a fork cannot do by itself, and how these tests stand in for it:
/// - ArbSys (0x64) has no code a fork runs: ForkArbSys answers the fork's block number, which on
///   the fork is the chain's own.
/// - Chainlink posts no new rounds on a fork, and the stock feeds hold Friday's close over a
///   weekend. As the clock moves, the feeds' latest rounds are re-dated to the moment (same round,
///   same answer, updatedAt now), as the live feeds' heartbeats would; the prices never move.
/// - The pool may be empty: the owner's liquidity goes in as SPEC 3.1's console fallback adds it
///   (900,000,000 $KYZN and 2 ETH by direct transfer and pair.mint, untaxed since the pool holds
///   no liquidity yet). On a chain where the pool already has liquidity, that pool is used.
abstract contract SiliconMainnetFork is Test {
    KyznToken internal constant TOKEN = KyznToken(payable(Terms.KYZN));
    ISiliconForkPair internal constant POOL = ISiliconForkPair(Terms.PAIR);
    IERC20 internal constant USDG = IERC20(Terms.USDG);
    address internal constant OWNER = Terms.OWNER;
    uint256 internal constant LIQUIDITY_KYZN = 900_000_000e18;
    uint256 internal constant LIQUIDITY_ETH = 2 ether;
    uint256 internal constant MARKETS = 4;

    SiliconMainnet internal deployment;
    MarketCalendar internal calendar;
    KyznUsdOracle internal oracle;
    SiliconVault internal vault;
    SiliconFeeRouter internal feeRouter;
    SiliconSwapAdapter internal swapAdapter;
    SiliconSynth[4] internal synths;
    StockIndexFeed[4] internal feeds;
    /// The deployment's gas and the logs it emitted.
    uint256 internal deployGas;
    Vm.Log[] internal deployLogs;
    SiliconIsolationProbe internal probe;

    function _fork() internal {
        string memory url = vm.envOr("ROBINHOOD_RPC_URL", string(""));
        if (bytes(url).length == 0) vm.skip(true, "ROBINHOOD_RPC_URL is not set");
        vm.createSelectFork(url);
        assertEq(block.chainid, RH.CHAIN_ID, "the fork is not Robinhood Chain mainnet");
        vm.etch(Terms.ARB_SYS, type(ForkArbSys).runtimeCode);
        // Gas for the owner's transactions and the 2 ETH of liquidity, on top of what it holds.
        vm.deal(OWNER, OWNER.balance + 10 ether);
        probe = new SiliconIsolationProbe();
    }

    // ---------------------------------------------------------------- the owner's transactions

    /// The owner wallet deploys SiliconMainnet: its creation code alone, no arguments, as the
    /// launch console sends it.
    function _deploy() internal {
        bytes memory initcode = type(SiliconMainnet).creationCode;
        vm.recordLogs();
        vm.prank(OWNER);
        uint256 before = gasleft();
        address d;
        assembly ("memory-safe") {
            d := create(0, add(initcode, 0x20), mload(initcode))
        }
        uint256 spent = before - gasleft();
        assertTrue(d != address(0), "the deployment reverted");
        // Isolated, what the test spent beyond its own CREATE is the transaction's execution;
        // otherwise add the transaction's 21,000 and its calldata.
        deployGas =
            _isolated() ? spent - 32_000 - 2 * ((initcode.length + 31) / 32) : spent + 21_000 + _calldataGas(initcode);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            deployLogs.push(logs[i]);
        }
        deployment = SiliconMainnet(d);
        calendar = deployment.calendar();
        oracle = deployment.oracle();
        vault = deployment.vault();
        feeRouter = deployment.feeRouter();
        swapAdapter = deployment.swapAdapter();
        synths = deployment.synths();
        feeds = deployment.feeds();
    }

    /// The owner accepts each contract offered to it: the calendar, the vault, the fee router and
    /// the four feeds. Returns the gas of each, in that order.
    function _acceptAll() internal returns (uint256[7] memory gas_) {
        address[7] memory owned = _owned();
        for (uint256 i; i < owned.length; ++i) {
            vm.prank(OWNER);
            Ownable2Step(owned[i]).acceptOwnership();
            gas_[i] = _callGas(abi.encodeCall(Ownable2Step.acceptOwnership, ()));
        }
    }

    /// Every contract the deployment offers the owner.
    function _owned() internal view returns (address[7] memory) {
        return [
            address(calendar),
            address(vault),
            address(feeRouter),
            address(feeds[0]),
            address(feeds[1]),
            address(feeds[2]),
            address(feeds[3])
        ];
    }

    /// The owner's liquidity, when the pool has none yet: 900,000,000 $KYZN and 2 ETH (SPEC 3.1).
    function _addLiquidity() internal {
        if (POOL.totalSupply() != 0) return;
        vm.startPrank(OWNER);
        TOKEN.transfer(address(POOL), LIQUIDITY_KYZN);
        IWETH(RH.WETH).deposit{value: LIQUIDITY_ETH}();
        IWETH(RH.WETH).transfer(address(POOL), LIQUIDITY_ETH);
        POOL.mint(OWNER);
        vm.stopPrank();
    }

    /// The owner opens the four markets. Returns the gas of each.
    function _openAll() internal returns (uint256[4] memory gas_) {
        for (uint256 id; id < MARKETS; ++id) {
            vm.prank(OWNER);
            vault.openMarket(id);
            gas_[id] = _callGas(abi.encodeCall(SiliconVault.openMarket, (id)));
        }
    }

    // ---------------------------------------------------------------- time and prices

    /// Re-dates the latest round of ETH/USD and of the seven stock feeds to now: same round, same
    /// answer, as each feed's next heartbeat would.
    function _freshFeeds() internal {
        _stampNow(RH.ETH_USD_FEED);
        address[7] memory stocks =
            [RH.NVDA_USD, RH.AMD_USD, RH.MU_USD, RH.SNDK_USD, RH.TSM_USD, RH.INTC_USD, RH.ASML_USD];
        for (uint256 i; i < stocks.length; ++i) {
            _stampNow(stocks[i]);
        }
    }

    function _stampNow(address feed) internal {
        (uint80 round, int256 answer, uint256 startedAt,, uint80 answeredIn) = IAggregatorV3(feed).latestRoundData();
        vm.mockCall(
            feed,
            abi.encodeCall(IAggregatorV3.latestRoundData, ()),
            abi.encode(round, answer, startedAt, block.timestamp, answeredIn)
        );
    }

    /// Moves the clock to `to`, an hour at a time, with the worker's oracle update() each hour.
    function _advance(uint256 to) internal {
        while (block.timestamp < to) {
            vm.warp(Math.min(block.timestamp + 1 hours, to));
            vm.roll(block.number + 1);
            _freshFeeds();
            oracle.update();
        }
    }

    /// 15:00 UTC on the first Monday at or after `notBefore` that the calendar leaves regular.
    function _mondayWindow(uint256 notBefore) internal view returns (uint256 t) {
        for (uint256 day = notBefore / 1 days;; ++day) {
            t = day * 1 days + 15 hours;
            if ((day + 4) % 7 == 1 && t >= notBefore && calendar.dayKind(day) == MarketCalendar.DayKind.Regular) {
                return t;
            }
        }
    }

    /// $KYZN in USD (18 decimals) as the oracle must price it once the pool has stood still for a
    /// long window: the pool's spot price in WETH (UQ112.112, truncated as Uniswap v2 accumulates
    /// it) times ETH/USD.
    function _expectedKyznUsd() internal view returns (uint256) {
        (uint112 r0, uint112 r1,) = POOL.getReserves();
        bool kyznIs0 = POOL.token0() == address(TOKEN);
        uint256 spot = kyznIs0 ? (uint256(r1) << 112) / r0 : (uint256(r0) << 112) / r1;
        uint256 kyznInEth = Math.mulDiv(spot, 1e18, 2 ** 112);
        (, int256 ethUsd,,,) = IAggregatorV3(RH.ETH_USD_FEED).latestRoundData();
        // ETH/USD answers with 8 decimals and a positive price.
        // forge-lint: disable-next-line(unsafe-typecast)
        return Math.mulDiv(kyznInEth, uint256(ethUsd) * 1e10, 1e18);
    }

    // ---------------------------------------------------------------- accounts

    /// `who` holds `kyznAmount` $KYZN and `usdgAmount` USDG and has approved the vault for both.
    function _fund(address who, uint256 kyznAmount, uint256 usdgAmount) internal {
        deal(address(TOKEN), who, kyznAmount);
        deal(address(USDG), who, usdgAmount);
        vm.startPrank(who);
        TOKEN.approve(address(vault), kyznAmount);
        USDG.approve(address(vault), usdgAmount);
        vm.stopPrank();
    }

    // ---------------------------------------------------------------- gas

    /// The last call's gas as a transaction of its own (isolated), or its execution plus the
    /// transaction's 21,000 and calldata.
    function _callGas(bytes memory data) internal returns (uint256) {
        uint256 used = vm.lastCallGas().gasTotalUsed;
        if (_isolated()) return used;
        return used + 21_000 + _calldataGas(data);
    }

    /// Whether forge runs each call as a transaction of its own (forge test --isolate).
    function _isolated() internal returns (bool) {
        probe.ping();
        return vm.lastCallGas().gasTotalUsed >= 21_000;
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 gas_) {
        for (uint256 i; i < data.length; ++i) {
            gas_ += data[i] == 0 ? 4 : 16;
        }
    }
}
