// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {KyznToken} from "../src/KyznToken.sol";
import {IWETH} from "../src/interfaces/IWETH.sol";
import {ISablierLockup} from "./interfaces/ISablierLockup.sol";
import {Months} from "./lib/Months.sol";
import {RobinhoodChain} from "./RobinhoodChain.sol";

/// @notice The $KYZN/WETH pair, as far as the liquidity step needs it.
interface ILiquidityPair {
    function mint(address to) external returns (uint256 liquidity);
    function totalSupply() external view returns (uint256);
}

/// @title Kyzen Network liquidity and team stream
/// @notice Step three of the launch (SPEC 3.1), once the protocol is set in the token and its owner
/// owns the Reserve, Staking and the Gateway. In one call from the token's owner, `launch`:
///   1. streams 100,000,000 $KYZN (10%) to the team wallet on Sablier: a 6-month cliff, then linear
///      to 18 months, not cancelable, not transferable, counted from this call (owner decision:
///      the cliff starts with trading);
///   2. pairs 900,000,000 $KYZN (90%) with the liquidity ETH in the Uniswap v2 pool and mints the LP
///      tokens to the owner (all but Uniswap's permanent 1,000), who locks them on UNCX by hand
///      right after.
/// Trading starts with it. Use: deploy it from the token's owner, approve it for 1,000,000,000
/// $KYZN, then call `launch` with the liquidity ETH. It runs once, keeps nothing (any ETH someone
/// sent it ahead goes to the owner), and has no other function that can change anything.
/// @dev The liquidity goes in by direct transfer and `pair.mint`, never through the router: a pair
/// that someone sent WETH to and synced before the first liquidity makes Router02's quote revert,
/// while `mint` counts exactly what reached the pair. `launch` refuses a pair that already has
/// liquidity tokens: someone holding $KYZN could have priced the pool first. It also refuses
/// protocol contracts the owner does not own, so contracts someone else built for this token can
/// never be the ones trading starts with.
contract KyzenLiquidity {
    using SafeERC20 for IERC20;

    /// @notice 10% of supply: the team's Sablier stream (SPEC 3.1). `uint128` is Sablier's deposit type.
    uint128 public constant TEAM_STREAM = 100_000_000e18;
    /// @notice 90% of supply: the starting liquidity (SPEC 3.1).
    uint256 public constant LIQUIDITY_KYZN = 900_000_000e18;
    /// @notice The team stream's cliff: nothing unlocks before it.
    uint256 public constant CLIFF_MONTHS = 6;
    /// @notice The team stream's end, counted from its start, as is the cliff.
    uint256 public constant STREAM_MONTHS = 18;

    /// Everything the step needs that is not fixed by SPEC. KyzenMainnetLiquidity fills it for
    /// Robinhood Chain.
    struct Setup {
        KyznToken token;
        ISablierLockup sablier;
        uint256 liquidityEth;
        /// address(0): the deployer.
        address teamWallet;
    }

    /// @notice The $KYZN token.
    KyznToken public immutable token;
    /// @notice The $KYZN/WETH pair the liquidity goes into.
    address public immutable pair;
    /// @notice Sablier Lockup, which holds the team stream.
    ISablierLockup public immutable sablier;
    /// @notice The token's owner, who deployed this contract: the only caller of `launch`, the
    /// stream's sender and the LP tokens' holder.
    address public immutable owner;
    /// @notice The stream's recipient.
    address public immutable teamWallet;
    /// @notice The ETH `launch` takes and pairs with the $KYZN.
    uint256 public immutable liquidityEth;

    /// @notice Whether `launch` has run.
    bool public launched;
    /// @notice The team stream's Sablier ID, once launched.
    uint256 public streamId;
    /// @notice The LP tokens minted to the owner, once launched.
    uint256 public lpTokens;

    /// @notice The team stream is created and the liquidity is in the pool.
    event Launched(address indexed owner, uint256 streamId, uint256 lpTokens);

    /// @notice The deployer is not the token's owner, which `owner` is.
    error NotTokenOwner(address owner);
    /// @notice Only the owner calls `launch`.
    error NotOwner();
    error AlreadyLaunched();
    /// @notice `launch` takes exactly the liquidity ETH.
    error WrongValue(uint256 needed, uint256 sent);
    /// @notice The token's Reserve, Staking and Gateway are not set yet: set them first (step two).
    error ProtocolNotSet();
    /// @notice The token's Reserve, Staking or Gateway is not owned by the owner: accept their
    /// ownership first (step two).
    error ProtocolNotOwned();
    /// @notice The pair already has liquidity tokens: someone priced the pool first.
    error PoolAlreadyStarted();
    /// @notice The team wallet is the token, its pair, WETH, the router, Sablier or this contract:
    /// a stream there could never be withdrawn by the team.
    error BadTeamWallet();
    /// @notice Some $KYZN or LP would stay in this contract.
    error LeftBehind();
    /// @notice The owner wallet did not take back ETH someone sent this contract ahead.
    error RefundFailed();

    constructor(Setup memory s) {
        address tokenOwner = s.token.owner();
        if (tokenOwner != msg.sender) revert NotTokenOwner(tokenOwner);
        address pair_ = s.token.pair();
        address team = s.teamWallet == address(0) ? msg.sender : s.teamWallet;
        if (
            team == address(s.token) || team == pair_ || team == s.token.weth() || team == address(s.token.router())
                || team == address(s.sablier) || team == address(this)
        ) revert BadTeamWallet();
        token = s.token;
        pair = pair_;
        sablier = s.sablier;
        owner = msg.sender;
        teamWallet = team;
        liquidityEth = s.liquidityEth;
    }

    /// @notice Creates the team stream and adds the liquidity. Takes 1,000,000,000 $KYZN from the
    /// owner (approve this contract first) and exactly `liquidityEth`.
    function launch() external payable {
        if (msg.sender != owner) revert NotOwner();
        if (launched) revert AlreadyLaunched();
        if (msg.value != liquidityEth) revert WrongValue(liquidityEth, msg.value);
        if (token.reserve() == address(0)) revert ProtocolNotSet();
        if (!_owned(token.reserve()) || !_owned(token.staking()) || !_owned(token.gateway())) {
            revert ProtocolNotOwned();
        }
        if (ILiquidityPair(pair).totalSupply() != 0) revert PoolAlreadyStarted();
        launched = true;

        IERC20 kyzn = IERC20(address(token));
        kyzn.safeTransferFrom(msg.sender, address(this), TEAM_STREAM + LIQUIDITY_KYZN);
        uint256 id = _stream(kyzn);
        uint256 lp = _addLiquidity(kyzn);
        if (kyzn.balanceOf(address(this)) != 0 || IERC20(pair).balanceOf(address(this)) != 0) revert LeftBehind();
        streamId = id;
        lpTokens = lp;
        // ETH someone sent here ahead (to the predictable address, or by selfdestruct) goes to the
        // owner, so it can never stop the launch.
        uint256 rest = address(this).balance;
        if (rest != 0) {
            (bool ok,) = payable(msg.sender).call{value: rest}("");
            if (!ok) revert RefundFailed();
        }
        emit Launched(msg.sender, id, lp);
    }

    /// Whether `protocolContract` is owned by the owner (acceptOwnership done).
    function _owned(address protocolContract) private view returns (bool) {
        return Ownable(protocolContract).owner() == owner;
    }

    /// SPEC 3.1: from now, a 6-month cliff with nothing unlocked at the start or the cliff, then
    /// linear to 18 months, one-second granularity, shape "cliff". The owner is the stream's sender,
    /// which Sablier also uses to look up its withdrawal fee.
    function _stream(IERC20 kyzn) private returns (uint256) {
        // Robinhood Chain timestamps fit uint40 for tens of thousands of years yet.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 start = uint40(block.timestamp);
        kyzn.forceApprove(address(sablier), TEAM_STREAM);
        return sablier.createWithTimestampsLL(
            ISablierLockup.CreateWithTimestamps({
                sender: owner,
                recipient: teamWallet,
                depositAmount: TEAM_STREAM,
                token: kyzn,
                cancelable: false,
                transferable: false,
                // forge-lint: disable-next-line(unsafe-typecast)
                timestamps: ISablierLockup.Timestamps({start: start, end: uint40(Months.add(start, STREAM_MONTHS))}),
                shape: "cliff"
            }),
            ISablierLockup.UnlockAmounts({start: 0, cliff: 0}),
            0,
            // forge-lint: disable-next-line(unsafe-typecast)
            uint40(Months.add(start, CLIFF_MONTHS))
        );
    }

    /// Pairs the $KYZN with the liquidity ETH, as WETH, and mints the LP tokens to the owner (all but
    /// Uniswap's permanent 1,000). Returns the LP minted.
    function _addLiquidity(IERC20 kyzn) private returns (uint256) {
        kyzn.safeTransfer(pair, LIQUIDITY_KYZN);
        IWETH weth = IWETH(token.weth());
        weth.deposit{value: liquidityEth}();
        IERC20(address(weth)).safeTransfer(pair, liquidityEth);
        return ILiquidityPair(pair).mint(owner);
    }
}

/// @notice The liquidity step was deployed on another chain than Robinhood Chain.
error WrongChain(uint256 chainId);
/// @notice The token does not trade through Robinhood Chain's Uniswap v2 Router02.
error NotRobinhoodToken(address router);

/// @notice Robinhood Chain's Sablier Lockup and SPEC 3.1's 2 ETH, with the owner's team wallet
/// (zero: the deploying wallet).
function mainnetLiquiditySetup(KyznToken token, address teamWallet) view returns (KyzenLiquidity.Setup memory s) {
    if (block.chainid != RobinhoodChain.CHAIN_ID) revert WrongChain(block.chainid);
    address router = address(token.router());
    if (router != RobinhoodChain.UNISWAP_V2_ROUTER) revert NotRobinhoodToken(router);
    s.token = token;
    s.sablier = ISablierLockup(RobinhoodChain.SABLIER_LOCKUP);
    s.liquidityEth = 2 ether;
    s.teamWallet = teamWallet;
}

/// @title Kyzen Network mainnet liquidity and team stream
/// @notice Robinhood Chain (chain ID 4663): the team stream on Sablier and 900,000,000 $KYZN with
/// 2 ETH in the Uniswap v2 pool; see KyzenLiquidity for every step.
contract KyzenMainnetLiquidity is KyzenLiquidity {
    /// @param token The deployed $KYZN token. The deployer must be its owner.
    /// @param teamWallet Receives the team's 100,000,000 $KYZN through the Sablier stream; the stream
    /// cannot be moved. Zero: the deploying wallet.
    constructor(KyznToken token, address teamWallet) KyzenLiquidity(mainnetLiquiditySetup(token, teamWallet)) {}
}
