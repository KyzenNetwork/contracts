// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KyznToken} from "../../src/KyznToken.sol";
import {IUniswapV2Router02} from "../../src/interfaces/IUniswapV2.sol";
import {KyzenLaunch} from "../KyzenLaunch.sol";
import {RobinhoodChain} from "../RobinhoodChain.sol";
import {TestnetStockToken} from "./TestnetStockToken.sol";
import {TestnetFeed} from "./TestnetFeed.sol";
import {TestnetSablierLockup} from "./TestnetSablierLockup.sol";
import {TestnetScript, ITestnetUniswapV2Factory, ITestnetUniswapV2Router} from "./TestnetScript.sol";

/// The whole Kyzen Network stack on Robinhood Chain testnet (46630), or on an anvil fork of it
/// (31337) for a rehearsal, launched by the same one-transaction KyzenLaunch the mainnet deploy
/// runs. The testnet has WETH but no Uniswap v2, stock tokens, Chainlink feeds, Sablier or UNCX,
/// so this script:
///   1. deploys NVDA and AMD stand-ins (TestnetStockToken) and owner-set feeds (TestnetFeed) for
///      NVDA/USD, AMD/USD and ETH/USD, priced from the mainnet Chainlink feeds on the day;
///   2. deploys the official Uniswap v2 factory and Router02, unmodified, from their build
///      artifacts in external/uniswap-v2 (vm.getCode), and checks with a probe pair (WETH/NVDA)
///      that the factory creates pairs where Router02 expects them, before any $KYZN exists;
///   3. deploys a stand-in for Sablier Lockup, and seeds a WETH/NVDA and a WETH/AMD pool at the
///      feed prices;
///   4. launches in one transaction with KyzenLaunch: the five contracts, the two stand-ins
///      listed in stage 0 (design), the keeper, Router02 queued as the Reserve's swap target (live
///      24 hours later), the operator, the team stream, the $KYZN liquidity (its LP tokens to the
///      deployer, as on mainnet, where the owner then locks them on UNCX by hand) and trading at the
///      launch taxes;
///   5. accepts ownership of the five contracts, as the owner does on mainnet after the launch;
///   6. writes every address to deployments/<chainId>.json.
///
/// The deployer is the `--private-key` (or `--sender`) address: it owns every contract, the
/// stand-ins and the feeds, and is the LP lock's withdrawer. Set KYZEN_KEEPER to the deployer's
/// address too: Exercise.keeperBuy() re-stamps the feeds (owner-only) and buys (keeper-only) with
/// one key. The launch contract is larger than Ethereum's 24 KB code limit allows for its creation
/// code, as Robinhood Chain permits (96 KB): run with --disable-code-size-limit so the local
/// simulation matches the chain.
///
/// Environment:
///   KYZEN_DEV_WALLET, KYZEN_TEAM_WALLET, KYZEN_HOST_PAYOUT, KYZEN_KEEPER, KYZEN_OPERATOR
///       the owner's settings, as in script/KyzenMainnetLaunch.sol
///   KYZEN_TESTNET_NVDA_USD, KYZEN_TESTNET_AMD_USD, KYZEN_TESTNET_ETH_USD
///       the mainnet Chainlink answers on the day (8 decimals), for example
///       cast call 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15 "latestRoundData()(uint80,int256,uint256,uint256,uint80)"
///       --rpc-url https://rpc.mainnet.chain.robinhood.com (NVDA/USD; AMD/USD and ETH/USD are in RobinhoodChain.sol)
///   KYZEN_LIQUIDITY_ETH      wei paired with 900,000,000 $KYZN (a testnet amount; SPEC 3.1: 2 ETH on mainnet)
///   KYZEN_TESTNET_POOL_ETH   wei of WETH in each of the WETH/NVDA and WETH/AMD pools
contract DeployTestnet is TestnetScript {
    using SafeERC20 for IERC20;

    struct Prices {
        int256 nvda;
        int256 amd;
        int256 eth;
    }

    error BadPrice(string name);
    error ZeroAmount(string name);

    function run() external returns (Addresses memory a) {
        _checkChain();
        Prices memory p = Prices({
            nvda: _price("KYZEN_TESTNET_NVDA_USD"),
            amd: _price("KYZEN_TESTNET_AMD_USD"),
            eth: _price("KYZEN_TESTNET_ETH_USD")
        });
        uint256 liquidityEth = _amount("KYZEN_LIQUIDITY_ETH");
        uint256 poolEth = _amount("KYZEN_TESTNET_POOL_ETH");
        a.deployer = msg.sender;

        // 1 to 3. Stand-ins, feeds, Uniswap v2 and the probe pair, UNCX and Sablier stand-ins, and
        // the two stock pools.
        vm.startBroadcast(a.deployer);
        a.nvda = address(new TestnetStockToken("NVDA testnet stand-in", "NVDA"));
        a.amd = address(new TestnetStockToken("AMD testnet stand-in", "AMD"));
        a.nvdaFeed = address(new TestnetFeed("NVDA / USD testnet stand-in", p.nvda));
        a.amdFeed = address(new TestnetFeed("AMD / USD testnet stand-in", p.amd));
        a.ethUsdFeed = address(new TestnetFeed("ETH / USD testnet stand-in", p.eth));
        a.factory = deployCode(FACTORY_ARTIFACT, abi.encode(a.deployer)); // feeToSetter; the fee stays off
        a.router = deployCode(ROUTER_ARTIFACT, abi.encode(a.factory, WETH));
        a.nvdaPair = ITestnetUniswapV2Factory(a.factory).createPair(a.nvda, WETH);
        TestnetSablierLockup sablier = new TestnetSablierLockup();
        _seed(a.router, TestnetStockToken(a.nvda), poolEth, p.eth, p.nvda, a.deployer);
        _seed(a.router, TestnetStockToken(a.amd), poolEth, p.eth, p.amd, a.deployer);
        vm.stopBroadcast();
        _checkPair(a.factory, a.nvda, WETH, a.nvdaPair);
        a.amdPair = ITestnetUniswapV2Factory(a.factory).getPair(a.amd, WETH);
        _checkPair(a.factory, a.amd, WETH, a.amdPair);

        // 4 and 5. The launch, in one transaction, then the owner accepts the five contracts.
        KyzenLaunch.Setup memory s = _setup(a, sablier, liquidityEth);
        vm.startBroadcast(a.deployer);
        KyzenLaunch launch = new KyzenLaunch{value: liquidityEth}(s);
        KyznToken token = launch.token();
        token.acceptOwnership();
        launch.registry().acceptOwnership();
        launch.reserve().acceptOwnership();
        launch.staking().acceptOwnership();
        launch.gateway().acceptOwnership();
        vm.stopBroadcast();

        a.token = address(token);
        a.pair = launch.pair();
        a.registry = address(launch.registry());
        a.reserve = address(launch.reserve());
        a.staking = address(launch.staking());
        a.gateway = address(launch.gateway());
        a.devWallet = token.devWallet();
        a.hostPayout = launch.gateway().hostPayout();
        a.keeper = launch.reserve().keeper();
        a.operator = launch.gateway().operator();
        _checkPair(a.factory, a.token, WETH, a.pair);

        _log(a, launch, liquidityEth, poolEth);
        _write(a);
    }

    /// The testnet stack in place of Robinhood Chain mainnet's, with the owner's settings from the
    /// environment.
    function _setup(Addresses memory a, TestnetSablierLockup sablier, uint256 liquidityEth)
        private
        view
        returns (KyzenLaunch.Setup memory s)
    {
        s.router = IUniswapV2Router02(a.router);
        s.ethUsdFeed = a.ethUsdFeed;
        s.assets = new RobinhoodChain.Asset[](2);
        s.assets[0] = RobinhoodChain.Asset({token: a.nvda, feed: a.nvdaFeed, stage: 0});
        s.assets[1] = RobinhoodChain.Asset({token: a.amd, feed: a.amdFeed, stage: 0});
        s.equityAssetA = a.nvda;
        s.equityAssetB = a.amd;
        s.swapTarget = a.router;
        s.sablier = sablier;
        s.liquidityEth = liquidityEth;
        s.devWallet = vm.envAddress("KYZEN_DEV_WALLET");
        s.teamWallet = vm.envAddress("KYZEN_TEAM_WALLET");
        s.hostPayout = vm.envAddress("KYZEN_HOST_PAYOUT");
        s.keeper = vm.envAddress("KYZEN_KEEPER");
        s.operator = vm.envAddress("KYZEN_OPERATOR");
    }

    /// Mints `stockUsd`-priced stand-in tokens worth `ethAmount` at `ethUsd` and adds both through
    /// Router02, so the pool price equals the feed prices. Both answers have 8 decimals.
    function _seed(
        address router,
        TestnetStockToken stock,
        uint256 ethAmount,
        int256 ethUsd,
        int256 stockUsd,
        address to
    ) private {
        // Both answers were checked positive in _price.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 stockAmount = ethAmount * uint256(ethUsd) / uint256(stockUsd);
        stock.mint(to, stockAmount);
        IERC20(address(stock)).forceApprove(router, stockAmount);
        ITestnetUniswapV2Router(router).addLiquidityETH{value: ethAmount}(
            address(stock), stockAmount, stockAmount, ethAmount, to, block.timestamp + DEADLINE_WINDOW
        );
    }

    function _price(string memory name) private view returns (int256 answer) {
        answer = vm.envInt(name);
        if (answer <= 0) revert BadPrice(name);
    }

    function _amount(string memory name) private view returns (uint256 amount) {
        amount = vm.envUint(name);
        if (amount == 0) revert ZeroAmount(name);
    }

    function _log(Addresses memory a, KyzenLaunch launch, uint256 liquidityEth, uint256 poolEth) private view {
        console2.log("Chain id                 ", block.chainid);
        console2.log("KyzenLaunch              ", address(launch));
        console2.log("Deployer (owner)         ", a.deployer);
        console2.log("Keeper                   ", a.keeper);
        if (a.keeper != a.deployer) console2.log("Keeper is not the deployer: keeperBuy() needs the feeds' owner too");
        console2.log("UniswapV2Factory         ", a.factory);
        console2.log("UniswapV2Router02        ", a.router);
        console2.log("KyznToken                ", a.token);
        console2.log("Pair ($KYZN/WETH)        ", a.pair);
        console2.log("WeightRegistry           ", a.registry);
        console2.log("Reserve                  ", a.reserve);
        console2.log("Staking                  ", a.staking);
        console2.log("GatewaySettlement        ", a.gateway);
        console2.log("NVDA stand-in            ", a.nvda);
        console2.log("NVDA/USD feed            ", a.nvdaFeed);
        console2.log("WETH/NVDA pair           ", a.nvdaPair);
        console2.log("AMD stand-in             ", a.amd);
        console2.log("AMD/USD feed             ", a.amdFeed);
        console2.log("WETH/AMD pair            ", a.amdPair);
        console2.log("ETH/USD feed             ", a.ethUsdFeed);
        console2.log("Liquidity ETH            ", _units(liquidityEth));
        console2.log("ETH per stock pool       ", _units(poolEth));
        console2.log("Team stream id           ", launch.streamId());
        console2.log("LP tokens (deployer)     ", _units(launch.lpTokens()));
        console2.log("Written to               ", _deploymentPath());
    }
}
