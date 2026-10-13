// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {Reserve} from "../src/Reserve.sol";
import {Staking} from "../src/Staking.sol";
import {GatewaySettlement} from "../src/GatewaySettlement.sol";
import {WeightRegistry} from "../src/WeightRegistry.sol";
import {RobinhoodChain as RH} from "./RobinhoodChain.sol";

interface IUniswapV2FactoryPairs {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/// Records the mainnet deployment, made from the owner's wallet where no broadcast writes
/// deployments/4663.json: the token alone, then the protocol (KyzenMainnetProtocol and the token's
/// setProtocolAddresses), then the liquidity and the team stream (SPEC 3.1). It runs once the
/// protocol is set in the token, before or after the liquidity. From the token's address alone it
/// reads every other address on chain (the token holds its pair and its Reserve, Staking and
/// Gateway; those hold the registry, the keeper, the operator and the host payout), checks that each
/// one has code, points back at the token, the Robinhood Chain router, WETH and feeds, and belongs
/// to the token's owner (owned, or offered to it until it accepts), and writes the keys the testnet
/// deployment writes (TestnetScript._write). It sends nothing.
///
///   KYZEN_TOKEN=0x... forge script script/RecordMainnet.s.sol --rpc-url robinhood
///   cd .. && node scripts/sync-deployments.mjs
contract RecordMainnet is Script {
    struct Record {
        address token;
        address pair;
        address registry;
        address reserve;
        address staking;
        address gateway;
        address owner;
        address devWallet;
        address hostPayout;
        address keeper;
        address operator;
    }

    error NotMainnet(uint256 chainId);
    error NoCode(string name, address account);
    error Mismatch(string what, address expected, address actual);
    /// The token's setProtocolAddresses has not been called: the protocol step is not done.
    error NotWired();
    /// A protocol contract belongs to someone other than the token's owner.
    error NotOwnedBy(string name, address expected, address actual);

    function run() external {
        if (block.chainid != RH.CHAIN_ID) revert NotMainnet(block.chainid);
        Record memory r = read(vm.envAddress("KYZEN_TOKEN"));
        _write(r);
        _report(r);
    }

    /// Every address of the deployment, read from the token and checked; reverts on the first
    /// address that is missing or points elsewhere.
    function read(address tokenAddr) public view returns (Record memory r) {
        _code("KyznToken", tokenAddr);
        KyznToken token = KyznToken(payable(tokenAddr));
        r.token = tokenAddr;
        _same("token.router", RH.UNISWAP_V2_ROUTER, address(token.router()));
        _same("token.weth", RH.WETH, token.weth());
        r.pair = token.pair();
        _same("token.pair", IUniswapV2FactoryPairs(RH.UNISWAP_V2_FACTORY).getPair(tokenAddr, RH.WETH), r.pair);
        _code("pair", r.pair);
        r.devWallet = token.devWallet();

        r.reserve = token.reserve();
        r.staking = token.staking();
        r.gateway = token.gateway();
        if (r.reserve == address(0) || r.staking == address(0) || r.gateway == address(0)) revert NotWired();
        _code("Reserve", r.reserve);
        _code("Staking", r.staking);
        _code("GatewaySettlement", r.gateway);

        Reserve reserve = Reserve(payable(r.reserve));
        _same("reserve.kyzn", tokenAddr, address(reserve.kyzn()));
        _same("reserve.weth", RH.WETH, address(reserve.weth()));
        _same("reserve.ethUsdFeed", RH.ETH_USD_FEED, reserve.ethUsdFeed());
        r.registry = address(reserve.registry());
        _code("WeightRegistry", r.registry);
        r.keeper = reserve.keeper();
        // The protocol is offered to the owner's wallet, which owns it once it accepts.
        address pending = reserve.pendingOwner();
        r.owner = pending != address(0) ? pending : reserve.owner();
        // Every protocol contract belongs to the token's owner: contracts someone else built for this
        // token, and set in it by mistake, are never recorded. (A renounced token has no owner to
        // compare with.)
        address tokenSide = token.pendingOwner() != address(0) ? token.pendingOwner() : token.owner();
        if (tokenSide != address(0)) {
            _ownedBy("WeightRegistry", r.registry, tokenSide);
            _ownedBy("Reserve", r.reserve, tokenSide);
            _ownedBy("Staking", r.staking, tokenSide);
            _ownedBy("GatewaySettlement", r.gateway, tokenSide);
        }

        Staking staking = Staking(payable(r.staking));
        _same("staking.kyzn", tokenAddr, address(staking.kyzn()));
        _same("staking.router", RH.UNISWAP_V2_ROUTER, address(staking.router()));
        _same("staking.weth", RH.WETH, address(staking.weth()));
        _same("staking.reserve", r.reserve, address(staking.reserve()));
        _same("staking.equityAssetA", RH.NVDA, staking.equityAssetA());
        _same("staking.equityAssetB", RH.AMD, staking.equityAssetB());

        GatewaySettlement gateway = GatewaySettlement(payable(r.gateway));
        _same("gateway.kyzn", tokenAddr, address(gateway.kyzn()));
        _same("gateway.router", RH.UNISWAP_V2_ROUTER, address(gateway.router()));
        r.hostPayout = gateway.hostPayout();
        r.operator = gateway.operator();
    }

    /// The contract's owner, or the owner it was offered to until it accepts, is `expected`.
    function _ownedBy(string memory name, address account, address expected) private view {
        Ownable2Step c = Ownable2Step(account);
        address side = c.pendingOwner() != address(0) ? c.pendingOwner() : c.owner();
        if (side != expected) revert NotOwnedBy(name, expected, side);
    }

    function _code(string memory name, address account) private view {
        if (account.code.length == 0) revert NoCode(name, account);
    }

    function _same(string memory what, address expected, address actual) private pure {
        if (expected != actual) revert Mismatch(what, expected, actual);
    }

    /// deployments/4663.json, with TestnetScript._write's keys ("deployer" is the owner wallet that
    /// deployed the protocol from the launch console: the Reserve's owner, or its pending owner until
    /// it accepts).
    function _write(Record memory r) private {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "deployer", r.owner);
        vm.serializeAddress(k, "weth", RH.WETH);
        vm.serializeAddress(k, "multicall3", 0xcA11bde05977b3631167028862bE2a173976CA11);
        vm.serializeAddress(k, "uniswapV2Factory", RH.UNISWAP_V2_FACTORY);
        vm.serializeAddress(k, "uniswapV2Router02", RH.UNISWAP_V2_ROUTER);
        vm.serializeAddress(k, "kyznToken", r.token);
        vm.serializeAddress(k, "kyznWethPair", r.pair);
        vm.serializeAddress(k, "weightRegistry", r.registry);
        vm.serializeAddress(k, "reserve", r.reserve);
        vm.serializeAddress(k, "staking", r.staking);
        vm.serializeAddress(k, "gatewaySettlement", r.gateway);
        vm.serializeAddress(k, "ethUsdFeed", RH.ETH_USD_FEED);
        vm.serializeAddress(k, "nvda", RH.NVDA);
        vm.serializeAddress(k, "amd", RH.AMD);
        vm.serializeAddress(k, "devWallet", r.devWallet);
        vm.serializeAddress(k, "hostPayout", r.hostPayout);
        vm.serializeAddress(k, "keeper", r.keeper);
        string memory json = vm.serializeAddress(k, "operator", r.operator);
        vm.writeJson(json, string.concat(vm.projectRoot(), "/deployments/", vm.toString(block.chainid), ".json"));
    }

    /// The launch state: owners (and owners still to accept), tax and trading.
    function _report(Record memory r) private view {
        KyznToken token = KyznToken(payable(r.token));
        console2.log("Recorded deployments/4663.json for", r.token);
        console2.log("  pair                ", r.pair);
        console2.log("  token deployed at   ", token.launchedAt());
        console2.log("  max wallet on       ", token.maxWalletActive());
        console2.log("  buy tax (bps)       ", token.buyTaxBps());
        console2.log("  sell tax (bps)      ", token.sellTaxBps());
        console2.log("  keeper              ", r.keeper);
        console2.log("  operator            ", r.operator);
        console2.log("  owner wallet        ", r.owner);
        _owner("  token owner         ", token.owner(), token.pendingOwner());
        _owner(
            "  Reserve owner       ", Reserve(payable(r.reserve)).owner(), Reserve(payable(r.reserve)).pendingOwner()
        );
        _owner(
            "  Staking owner       ", Staking(payable(r.staking)).owner(), Staking(payable(r.staking)).pendingOwner()
        );
        _owner(
            "  Gateway owner       ",
            GatewaySettlement(payable(r.gateway)).owner(),
            GatewaySettlement(payable(r.gateway)).pendingOwner()
        );
        _owner("  WeightRegistry owner", WeightRegistry(r.registry).owner(), WeightRegistry(r.registry).pendingOwner());
    }

    function _owner(string memory label, address owner, address pending) private pure {
        if (pending == address(0)) console2.log(label, owner);
        else console2.log(string.concat(label, " (to accept: acceptOwnership from)"), pending);
    }
}
