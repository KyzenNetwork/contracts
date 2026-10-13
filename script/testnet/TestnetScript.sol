// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script} from "forge-std/Script.sol";

/// The Uniswap v2 factory calls the testnet scripts make (the official v2-core factory).
interface ITestnetUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/// The Uniswap v2 Router02 calls the testnet scripts make (the official v2-periphery router).
interface ITestnetUniswapV2Router {
    function factory() external view returns (address);
    function WETH() external view returns (address);

    function addLiquidityETH(
        address token,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountEthMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountEth, uint256 liquidity);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);
    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory);

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external payable;

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external;
}

interface ITestnetUniswapV2Pair {
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function token0() external view returns (address);
}

/// What DeployTestnet and Exercise share: the chains they run on, the testnet's fixed addresses,
/// the Uniswap v2 pair address and the deployment file, deployments/<chainId>.json.
abstract contract TestnetScript is Script {
    uint256 internal constant ROBINHOOD_TESTNET = 46_630;
    /// An anvil fork of the testnet, for rehearsals.
    uint256 internal constant ANVIL = 31_337;
    /// On Robinhood Chain testnet (46630), verified on-chain; an anvil fork has it too.
    address internal constant WETH = 0x7943e237c7F95DA44E0301572D358911207852Fa;
    /// The canonical Multicall3, on both Robinhood Chain networks.
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;
    /// keccak256 of the official UniswapV2Pair creation code; Router02 derives pair addresses from it.
    bytes32 internal constant PAIR_INIT_CODE_HASH = 0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;
    string internal constant FACTORY_ARTIFACT = "external/uniswap-v2/UniswapV2Factory.json";
    string internal constant ROUTER_ARTIFACT = "external/uniswap-v2/UniswapV2Router02.json";
    /// Deadline for the scripts' router calls: the transaction is mined after the simulation.
    uint256 internal constant DEADLINE_WINDOW = 30 minutes;

    /// Every address of a testnet deployment, as written to deployments/<chainId>.json.
    struct Addresses {
        address deployer;
        address factory;
        address router;
        address token;
        address pair;
        address registry;
        address reserve;
        address staking;
        address gateway;
        address nvda;
        address nvdaFeed;
        address nvdaPair;
        address amd;
        address amdFeed;
        address amdPair;
        address ethUsdFeed;
        address devWallet;
        address hostPayout;
        address keeper;
        address operator;
    }

    error WrongChain(uint256 chainId);
    error NoWeth(address weth);
    error PairAddressMismatch(address tokenA, address tokenB, address expected, address actual);

    /// Robinhood Chain testnet or an anvil fork of it, never mainnet (4663).
    function _checkChain() internal view {
        if (block.chainid != ROBINHOOD_TESTNET && block.chainid != ANVIL) revert WrongChain(block.chainid);
        if (WETH.code.length == 0) revert NoWeth(WETH);
    }

    function _deploymentPath() internal view returns (string memory) {
        return string.concat("deployments/", vm.toString(block.chainid), ".json");
    }

    /// The pair address Router02 derives (UniswapV2Library.pairFor) from the init code hash.
    function _pairFor(address factory, address tokenA, address tokenB) internal pure returns (address) {
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        bytes32 hash = keccak256(abi.encodePacked(hex"ff", factory, salt, PAIR_INIT_CODE_HASH));
        // A CREATE2 address is the low 20 bytes of this hash by definition.
        // forge-lint: disable-next-line(unsafe-typecast)
        return address(uint160(uint256(hash)));
    }

    /// Reverts unless the factory's pair for (tokenA, tokenB) is `pair` and sits where Router02
    /// expects it; otherwise every router swap and liquidity call would target the wrong address.
    function _checkPair(address factory, address tokenA, address tokenB, address pair) internal view {
        address expected = _pairFor(factory, tokenA, tokenB);
        address actual = ITestnetUniswapV2Factory(factory).getPair(tokenA, tokenB);
        if (expected != actual || actual != pair || pair == address(0)) {
            revert PairAddressMismatch(tokenA, tokenB, expected, actual);
        }
    }

    function _path(address from, address to) internal pure returns (address[] memory path) {
        path = new address[](2);
        path[0] = from;
        path[1] = to;
    }

    function _write(Addresses memory a) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", a.deployer);
        vm.serializeAddress(k, "weth", WETH);
        vm.serializeAddress(k, "multicall3", MULTICALL3);
        vm.serializeAddress(k, "uniswapV2Factory", a.factory);
        vm.serializeAddress(k, "uniswapV2Router02", a.router);
        vm.serializeAddress(k, "kyznToken", a.token);
        vm.serializeAddress(k, "kyznWethPair", a.pair);
        vm.serializeAddress(k, "weightRegistry", a.registry);
        vm.serializeAddress(k, "reserve", a.reserve);
        vm.serializeAddress(k, "staking", a.staking);
        vm.serializeAddress(k, "gatewaySettlement", a.gateway);
        vm.serializeAddress(k, "nvda", a.nvda);
        vm.serializeAddress(k, "nvdaUsdFeed", a.nvdaFeed);
        vm.serializeAddress(k, "nvdaWethPair", a.nvdaPair);
        vm.serializeAddress(k, "amd", a.amd);
        vm.serializeAddress(k, "amdUsdFeed", a.amdFeed);
        vm.serializeAddress(k, "amdWethPair", a.amdPair);
        vm.serializeAddress(k, "ethUsdFeed", a.ethUsdFeed);
        vm.serializeAddress(k, "devWallet", a.devWallet);
        vm.serializeAddress(k, "hostPayout", a.hostPayout);
        vm.serializeAddress(k, "keeper", a.keeper);
        string memory json = vm.serializeAddress(k, "operator", a.operator);
        vm.writeJson(json, _deploymentPath());
    }

    function _load() internal view returns (Addresses memory a) {
        // Every Exercise entry point loads through here, so none can run off the testnet or anvil.
        _checkChain();
        // Reads only deployments/, which foundry.toml's fs_permissions allow.
        // forge-lint: disable-next-line(unsafe-cheatcode)
        string memory json = vm.readFile(_deploymentPath());
        a.deployer = vm.parseJsonAddress(json, ".deployer");
        a.factory = vm.parseJsonAddress(json, ".uniswapV2Factory");
        a.router = vm.parseJsonAddress(json, ".uniswapV2Router02");
        a.token = vm.parseJsonAddress(json, ".kyznToken");
        a.pair = vm.parseJsonAddress(json, ".kyznWethPair");
        a.registry = vm.parseJsonAddress(json, ".weightRegistry");
        a.reserve = vm.parseJsonAddress(json, ".reserve");
        a.staking = vm.parseJsonAddress(json, ".staking");
        a.gateway = vm.parseJsonAddress(json, ".gatewaySettlement");
        a.nvda = vm.parseJsonAddress(json, ".nvda");
        a.nvdaFeed = vm.parseJsonAddress(json, ".nvdaUsdFeed");
        a.nvdaPair = vm.parseJsonAddress(json, ".nvdaWethPair");
        a.amd = vm.parseJsonAddress(json, ".amd");
        a.amdFeed = vm.parseJsonAddress(json, ".amdUsdFeed");
        a.amdPair = vm.parseJsonAddress(json, ".amdWethPair");
        a.ethUsdFeed = vm.parseJsonAddress(json, ".ethUsdFeed");
        a.devWallet = vm.parseJsonAddress(json, ".devWallet");
        a.hostPayout = vm.parseJsonAddress(json, ".hostPayout");
        a.keeper = vm.parseJsonAddress(json, ".keeper");
        a.operator = vm.parseJsonAddress(json, ".operator");
    }

    /// `amount` (18 decimals) as a decimal string, for the logs.
    function _units(uint256 amount) internal pure returns (string memory) {
        uint256 whole = amount / 1e18;
        uint256 frac = amount % 1e18;
        if (frac == 0) return vm.toString(whole);
        bytes memory digits = bytes(vm.toString(frac + 1e18)); // "1" followed by 18 digits
        uint256 end = digits.length;
        while (digits[end - 1] == "0") --end;
        bytes memory fraction = new bytes(end - 1);
        for (uint256 i = 1; i < end; ++i) {
            fraction[i - 1] = digits[i];
        }
        return string.concat(vm.toString(whole), ".", string(fraction));
    }
}
