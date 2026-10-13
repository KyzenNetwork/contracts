// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {KyzenMainnetLaunch} from "./KyzenMainnetLaunch.sol";

/// The mainnet launch from the command line: the same single deployment as from the deploy page or
/// Remix, with the settings from the environment: KYZEN_KEEPER and KYZEN_OPERATOR (required), and
/// KYZEN_DEV_WALLET, KYZEN_TEAM_WALLET, KYZEN_HOST_PAYOUT (optional: unset is the deploying wallet).
/// It sends the 2 ETH of liquidity. See LAUNCH.md for the commands.
contract LaunchMainnet is Script {
    uint256 internal constant LIQUIDITY_ETH = 2 ether;

    function run() external returns (KyzenMainnetLaunch launch) {
        address dev = vm.envOr("KYZEN_DEV_WALLET", address(0));
        address team = vm.envOr("KYZEN_TEAM_WALLET", address(0));
        address host = vm.envOr("KYZEN_HOST_PAYOUT", address(0));
        address keeper = vm.envOr("KYZEN_KEEPER", address(0));
        address operator = vm.envOr("KYZEN_OPERATOR", address(0));
        vm.startBroadcast();
        launch = new KyzenMainnetLaunch{value: LIQUIDITY_ETH}(dev, team, host, keeper, operator);
        vm.stopBroadcast();
        console2.log("KyzenMainnetLaunch ", address(launch));
        console2.log("KyznToken          ", address(launch.token()));
        console2.log("Pair ($KYZN/WETH)  ", launch.pair());
        console2.log("WeightRegistry     ", address(launch.registry()));
        console2.log("Reserve            ", address(launch.reserve()));
        console2.log("Staking            ", address(launch.staking()));
        console2.log("GatewaySettlement  ", address(launch.gateway()));
        console2.log("Sablier stream id  ", launch.streamId());
        console2.log("LP tokens (owner)  ", launch.lpTokens());
    }
}
