// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {WeightRegistry} from "../src/WeightRegistry.sol";
import {Reserve} from "../src/Reserve.sol";
import {Staking} from "../src/Staking.sol";
import {GatewaySettlement} from "../src/GatewaySettlement.sol";
import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {IKyzn} from "../src/interfaces/IKyzn.sol";
import {IRotationState} from "../src/interfaces/IRotationState.sol";
import {IReserveView} from "../src/interfaces/IReserveView.sol";
import {ISablierLockup} from "./interfaces/ISablierLockup.sol";
import {Months} from "./lib/Months.sol";
import {RobinhoodChain} from "./RobinhoodChain.sol";

/// @notice The $KYZN/WETH pair, as far as the launch needs it.
interface ILaunchPair {
    function mint(address to) external returns (uint256 liquidity);
}

/// @title Kyzen Network launch, in one transaction
/// @notice Deploying this contract launches Kyzen Network (SPEC 3.1, Step 9). Everything runs in
/// its constructor, so either every step below happens or none does:
///   1. deploys the five contracts: WeightRegistry, KyznToken, Reserve, Staking, GatewaySettlement;
///   2. wires them: the Reserve's assets, keeper and swap target (usable 24 hours later), the
///      Gateway's operator, and the token's Reserve, Staking and Gateway addresses;
///   3. streams 100,000,000 $KYZN (10%) to the team wallet on Sablier: a 6-month cliff, then
///      linear to 18 months, not cancelable, not transferable;
///   4. pairs 900,000,000 $KYZN (90%) with the liquidity ETH in the Uniswap v2 pool and mints the
///      LP tokens to the deployer, who locks them on UNCX by hand right after (SPEC 3.1);
///   5. trading is open from here (the token has no switch), at the launch taxes: 5% on buys and
///      10% on sells, with the 2% max wallet on until the owner removes it;
///   6. hands the deployer ownership of all five contracts (each takes effect when the deployer
///      calls `acceptOwnership` on it) and refunds any ETH sent beyond the liquidity.
/// It keeps nothing: no $KYZN, no LP, no ETH, and no function that can change anything.
/// @dev The deployer is `msg.sender`: the stream's sender, the LP's holder, every contract's next
/// owner and the refund's recipient. Deploy it directly from the owner's wallet: deployed
/// through a factory (a CREATE2 deployer, for example), all of these would go to the factory.
/// The liquidity goes in by direct transfer and `pair.mint`: no router allowance, and the LP minted
/// covers exactly what reached the pair, including WETH anyone donated to a pair pre-created at
/// the token's predicted address (such a pair cannot be synced or minted before the token exists).
contract KyzenLaunch {
    using SafeERC20 for IERC20;

    /// 10% of supply: the team's Sablier stream (SPEC 3.1). `uint128` is Sablier's deposit type.
    uint128 public constant TEAM_STREAM = 100_000_000e18;
    /// 90% of supply: the starting liquidity (SPEC 3.1).
    uint256 public constant LIQUIDITY_KYZN = 900_000_000e18;
    uint256 public constant CLIFF_MONTHS = 6;
    uint256 public constant STREAM_MONTHS = 18;

    /// Everything the launch needs that is not fixed by SPEC 3.1: the chain's contracts and the
    /// owner's own addresses. KyzenMainnetLaunch fills it for Robinhood Chain.
    struct Setup {
        IUniswapV2Router02 router;
        address ethUsdFeed;
        RobinhoodChain.Asset[] assets;
        address equityAssetA;
        address equityAssetB;
        address swapTarget;
        ISablierLockup sablier;
        uint256 liquidityEth;
        /// address(0): the deployer.
        address devWallet;
        address teamWallet;
        address hostPayout;
        /// Required.
        address keeper;
        address operator;
    }

    KyznToken public immutable token;
    address public immutable pair;
    WeightRegistry public immutable registry;
    Reserve public immutable reserve;
    Staking public immutable staking;
    GatewaySettlement public immutable gateway;
    uint256 public immutable streamId;
    /// The LP tokens minted to the deployer, to lock on UNCX.
    uint256 public immutable lpTokens;

    event Launched(
        address indexed owner,
        KyznToken token,
        address pair,
        WeightRegistry registry,
        Reserve reserve,
        Staking staking,
        GatewaySettlement gateway,
        uint256 streamId,
        uint256 lpTokens
    );

    /// A required launch setting is still empty: the name is the setting to fill in.
    error SettingNotSet(string name);
    /// The deployment sent less ETH than the liquidity.
    error NotEnoughEth(uint256 needed, uint256 sent);
    /// Some $KYZN or LP would stay in this contract.
    error LeftBehind();
    error RefundFailed();

    constructor(Setup memory s) payable {
        // An empty development, team or host-payout wallet is the deploying owner's own wallet.
        if (s.devWallet == address(0)) s.devWallet = msg.sender;
        if (s.teamWallet == address(0)) s.teamWallet = msg.sender;
        if (s.hostPayout == address(0)) s.hostPayout = msg.sender;
        _check(s);

        registry = new WeightRegistry();
        token = new KyznToken(s.router, s.devWallet);
        pair = token.pair();
        reserve = new Reserve(
            IKyzn(address(token)), IWETH(token.weth()), s.ethUsdFeed, IRotationState(address(registry)), _assets(s)
        );
        staking = new Staking(
            IERC20(address(token)), s.router, IReserveView(address(reserve)), s.equityAssetA, s.equityAssetB
        );
        gateway = new GatewaySettlement(IKyzn(address(token)), s.router, s.hostPayout);

        _wire(s, token, reserve, staking, gateway);
        streamId = _stream(s, token);
        lpTokens = _addLiquidity(s, token, pair);

        if (token.balanceOf(address(this)) != 0 || IERC20(pair).balanceOf(address(this)) != 0) revert LeftBehind();
        registry.transferOwnership(msg.sender);
        token.transferOwnership(msg.sender);
        reserve.transferOwnership(msg.sender);
        staking.transferOwnership(msg.sender);
        gateway.transferOwnership(msg.sender);
        uint256 rest = address(this).balance;
        if (rest != 0) {
            (bool ok,) = payable(msg.sender).call{value: rest}("");
            if (!ok) revert RefundFailed();
        }
        emit Launched(msg.sender, token, pair, registry, reserve, staking, gateway, streamId, lpTokens);
    }

    /// Every setting before anything is deployed.
    function _check(Setup memory s) private view {
        if (s.keeper == address(0)) revert SettingNotSet("KEEPER");
        if (s.operator == address(0)) revert SettingNotSet("OPERATOR");
        if (msg.value < s.liquidityEth) revert NotEnoughEth(s.liquidityEth, msg.value);
    }

    /// The Reserve's assets, listed by its constructor.
    function _assets(Setup memory s) private pure returns (Reserve.AssetConfig[] memory list) {
        list = new Reserve.AssetConfig[](s.assets.length);
        for (uint256 i; i < s.assets.length; ++i) {
            list[i] = Reserve.AssetConfig({token: s.assets[i].token, feed: s.assets[i].feed, stage: s.assets[i].stage});
        }
    }

    /// The Reserve's keeper and swap target, the Gateway's operator, then the token's protocol
    /// addresses.
    function _wire(Setup memory s, KyznToken token_, Reserve reserve_, Staking staking_, GatewaySettlement gateway_)
        private
    {
        reserve_.setKeeper(s.keeper);
        reserve_.queueTarget(s.swapTarget, true);
        gateway_.setOperator(s.operator);
        token_.setProtocolAddresses(address(reserve_), address(staking_), address(gateway_));
    }

    /// SPEC 3.1: from now, a 6-month cliff with nothing unlocked at the start or the cliff, then
    /// linear to 18 months, one-second granularity, shape "cliff". The deployer is the stream's
    /// sender, which Sablier also uses to look up its withdrawal fee.
    function _stream(Setup memory s, KyznToken token_) private returns (uint256) {
        // Robinhood Chain timestamps fit uint40 for tens of thousands of years yet.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 start = uint40(block.timestamp);
        IERC20(address(token_)).forceApprove(address(s.sablier), TEAM_STREAM);
        return s.sablier
            .createWithTimestampsLL(
                ISablierLockup.CreateWithTimestamps({
                    sender: msg.sender,
                    recipient: s.teamWallet,
                    depositAmount: TEAM_STREAM,
                    token: IERC20(address(token_)),
                    cancelable: false,
                    transferable: false,
                    // forge-lint: disable-next-line(unsafe-typecast)
                    timestamps: ISablierLockup.Timestamps({
                        start: start, end: uint40(Months.add(start, STREAM_MONTHS))
                    }),
                    shape: "cliff"
                }),
                ISablierLockup.UnlockAmounts({start: 0, cliff: 0}),
                0,
                // forge-lint: disable-next-line(unsafe-typecast)
                uint40(Months.add(start, CLIFF_MONTHS))
            );
    }

    /// Pairs the $KYZN with the liquidity ETH, as WETH, and mints every LP token to the deployer,
    /// who locks them on UNCX by hand (SPEC 3.1). Returns the LP minted.
    function _addLiquidity(Setup memory s, KyznToken token_, address pair_) private returns (uint256) {
        IERC20(address(token_)).safeTransfer(pair_, LIQUIDITY_KYZN);
        IWETH weth = IWETH(token_.weth());
        weth.deposit{value: s.liquidityEth}();
        IERC20(address(weth)).safeTransfer(pair_, s.liquidityEth);
        return ILaunchPair(pair_).mint(msg.sender);
    }
}
