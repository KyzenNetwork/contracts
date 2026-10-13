// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {WeightRegistry} from "../src/WeightRegistry.sol";
import {Reserve} from "../src/Reserve.sol";
import {Staking} from "../src/Staking.sol";
import {GatewaySettlement} from "../src/GatewaySettlement.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IKyzn} from "../src/interfaces/IKyzn.sol";
import {IRotationState} from "../src/interfaces/IRotationState.sol";
import {IReserveView} from "../src/interfaces/IReserveView.sol";
import {RobinhoodChain} from "./RobinhoodChain.sol";

/// @title Kyzen Network protocol, for the deployed $KYZN token
/// @notice Step two of the launch: the token was deployed alone first (SPEC 3.1). Deploying this
/// contract, in one transaction:
///   1. deploys the WeightRegistry, the Reserve (listing the chain's stock tokens), Staking and the
///      GatewaySettlement contract, each built for the given token;
///   2. sets the Reserve's keeper, queues its swap target (usable 24 hours later) and sets the
///      Gateway's operator;
///   3. offers the deployer ownership of all four, each taking effect when the deployer calls
///      `acceptOwnership` on it.
/// The token's owner then sets them in the token with `setProtocolAddresses`, which only the token's
/// owner can call. This contract keeps nothing and has no function that can change anything.
/// @dev The deployer must be the token's owner, so one wallet owns the token and the whole protocol.
/// Deploy it directly from that wallet: deployed through a factory, it reverts NotTokenOwner.
contract KyzenProtocol {
    /// Everything the deployment needs that is not fixed by SPEC: the chain's contracts and the
    /// owner's addresses. KyzenMainnetProtocol fills it for Robinhood Chain.
    struct Setup {
        KyznToken token;
        address ethUsdFeed;
        RobinhoodChain.Asset[] assets;
        address equityAssetA;
        address equityAssetB;
        address swapTarget;
        /// Receives the ETH of each Gateway settlement. address(0): the deployer.
        address hostPayout;
        /// Required: sends the Reserve's purchases and sales.
        address keeper;
        /// Required: settles Gateway usage.
        address operator;
    }

    /// @notice The Scheduler's weight registry.
    WeightRegistry public immutable registry;
    /// @notice The Reserve.
    Reserve public immutable reserve;
    /// @notice Staking.
    Staking public immutable staking;
    /// @notice The Gateway settlement contract.
    GatewaySettlement public immutable gateway;

    /// @notice The four contracts are deployed and offered to `owner`.
    event Deployed(
        address indexed owner,
        KyznToken indexed token,
        WeightRegistry registry,
        Reserve reserve,
        Staking staking,
        GatewaySettlement gateway
    );

    /// @notice The deployer is not the token's owner, which `owner` is.
    error NotTokenOwner(address owner);
    /// @notice A required setting is empty: the name is the setting to fill in.
    error SettingNotSet(string name);

    constructor(Setup memory s) {
        address tokenOwner = s.token.owner();
        if (tokenOwner != msg.sender) revert NotTokenOwner(tokenOwner);
        if (s.keeper == address(0)) revert SettingNotSet("KEEPER");
        if (s.operator == address(0)) revert SettingNotSet("OPERATOR");
        if (s.hostPayout == address(0)) s.hostPayout = msg.sender;

        IKyzn kyzn = IKyzn(address(s.token));
        registry = new WeightRegistry();
        reserve = new Reserve(kyzn, IWETH(s.token.weth()), s.ethUsdFeed, IRotationState(address(registry)), _assets(s));
        staking = new Staking(
            IERC20(address(s.token)), s.token.router(), IReserveView(address(reserve)), s.equityAssetA, s.equityAssetB
        );
        gateway = new GatewaySettlement(kyzn, s.token.router(), s.hostPayout);

        reserve.setKeeper(s.keeper);
        reserve.queueTarget(s.swapTarget, true);
        gateway.setOperator(s.operator);

        registry.transferOwnership(msg.sender);
        reserve.transferOwnership(msg.sender);
        staking.transferOwnership(msg.sender);
        gateway.transferOwnership(msg.sender);
        emit Deployed(msg.sender, s.token, registry, reserve, staking, gateway);
    }

    /// The Reserve's assets, listed by its constructor.
    function _assets(Setup memory s) private pure returns (Reserve.AssetConfig[] memory list) {
        list = new Reserve.AssetConfig[](s.assets.length);
        for (uint256 i; i < s.assets.length; ++i) {
            list[i] = Reserve.AssetConfig({token: s.assets[i].token, feed: s.assets[i].feed, stage: s.assets[i].stage});
        }
    }
}

/// @notice The protocol was deployed on another chain than Robinhood Chain.
error WrongChain(uint256 chainId);
/// @notice The token does not trade through Robinhood Chain's Uniswap v2 Router02.
error NotRobinhoodToken(address router);

/// @notice Robinhood Chain's feeds, stock tokens and swap target (SPEC 3.2a), with the owner's
/// settings (zero host payout: the deploying wallet).
function mainnetProtocolSetup(KyznToken token, address hostPayout, address keeper, address operator)
    view
    returns (KyzenProtocol.Setup memory s)
{
    if (block.chainid != RobinhoodChain.CHAIN_ID) revert WrongChain(block.chainid);
    address router = address(token.router());
    if (router != RobinhoodChain.UNISWAP_V2_ROUTER) revert NotRobinhoodToken(router);
    s.token = token;
    s.ethUsdFeed = RobinhoodChain.ETH_USD_FEED;
    RobinhoodChain.Asset[7] memory list = RobinhoodChain.assets();
    s.assets = new RobinhoodChain.Asset[](list.length);
    for (uint256 i; i < list.length; ++i) {
        s.assets[i] = list[i];
    }
    s.equityAssetA = RobinhoodChain.NVDA;
    s.equityAssetB = RobinhoodChain.AMD;
    s.swapTarget = RobinhoodChain.UNISWAP_V3_SWAP_ROUTER_02;
    s.hostPayout = hostPayout;
    s.keeper = keeper;
    s.operator = operator;
}

/// @title Kyzen Network mainnet protocol
/// @notice Deploys the Reserve, Staking, the Gateway and the weight registry for the deployed
/// $KYZN token on Robinhood Chain (chain ID 4663); see KyzenProtocol for every step.
contract KyzenMainnetProtocol is KyzenProtocol {
    /// @param token The deployed $KYZN token. The deployer must be its owner.
    /// @param hostPayout Receives the ETH of each Gateway settlement, to pay the AI inference host.
    /// Zero: the deploying wallet.
    /// @param keeper Required. Sends the Reserve's purchases and sales from the server: a wallet
    /// holding only gas ETH, never the owner wallet.
    /// @param operator Required. Settles Gateway usage from the server: a wallet holding only gas
    /// ETH, never the owner wallet.
    constructor(KyznToken token, address hostPayout, address keeper, address operator)
        KyzenProtocol(mainnetProtocolSetup(token, hostPayout, keeper, operator))
    {}
}
