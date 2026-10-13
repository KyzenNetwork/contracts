// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IUniswapV2Router02} from "../src/interfaces/IUniswapV2.sol";
import {ISablierLockup} from "./interfaces/ISablierLockup.sol";
import {KyzenLaunch} from "./KyzenLaunch.sol";
import {RobinhoodChain} from "./RobinhoodChain.sol";

/// @notice The mainnet launch was deployed on another chain than Robinhood Chain.
error WrongChain(uint256 chainId);

/// @notice Robinhood Chain's contracts and SPEC 3.1's amounts, with the owner's settings (zero for
/// the optional wallets: the deploying wallet).
function mainnetSetup(address devWallet, address teamWallet, address hostPayout, address keeper, address operator)
    view
    returns (KyzenLaunch.Setup memory s)
{
    if (block.chainid != RobinhoodChain.CHAIN_ID) revert WrongChain(block.chainid);
    s.router = IUniswapV2Router02(RobinhoodChain.UNISWAP_V2_ROUTER);
    s.ethUsdFeed = RobinhoodChain.ETH_USD_FEED;
    RobinhoodChain.Asset[7] memory list = RobinhoodChain.assets();
    s.assets = new RobinhoodChain.Asset[](list.length);
    for (uint256 i; i < list.length; ++i) {
        s.assets[i] = list[i];
    }
    s.equityAssetA = RobinhoodChain.NVDA;
    s.equityAssetB = RobinhoodChain.AMD;
    s.swapTarget = RobinhoodChain.UNISWAP_V3_SWAP_ROUTER_02;
    s.sablier = ISablierLockup(RobinhoodChain.SABLIER_LOCKUP);
    s.liquidityEth = 2 ether;
    s.devWallet = devWallet;
    s.teamWallet = teamWallet;
    s.hostPayout = hostPayout;
    s.keeper = keeper;
    s.operator = operator;
}

/// @title Kyzen Network mainnet launch
/// @notice Deploying this launches Kyzen Network on Robinhood Chain (chain ID 4663) in one
/// transaction (see KyzenLaunch for every step). Send 2 ETH with it, the liquidity; anything above
/// is sent back. The LP tokens go to the deploying wallet, which locks them on UNCX right after.
contract KyzenMainnetLaunch is KyzenLaunch {
    /// @param devWallet Receives the development share of the tax in ETH, held in the token and sent
    /// to it by sendHeldEth (the server calls it after each tax sale). Zero: the deploying wallet.
    /// @param teamWallet Receives the team's 100,000,000 $KYZN on Sablier: a 6-month cliff, then
    /// linear to 18 months; the stream cannot be moved. Zero: the deploying wallet.
    /// @param hostPayout Receives the ETH of each Gateway settlement, to pay the AI inference host.
    /// Zero: the deploying wallet.
    /// @param keeper Required. Sends the Reserve's purchases and sales from the server: a fresh
    /// wallet holding only gas ETH, never the owner wallet.
    /// @param operator Required. Settles Gateway usage, funds staking and sends the development ETH,
    /// from the server: a fresh wallet holding only gas ETH, never the owner wallet.
    constructor(address devWallet, address teamWallet, address hostPayout, address keeper, address operator)
        payable
        KyzenLaunch(mainnetSetup(devWallet, teamWallet, hostPayout, keeper, operator))
    {}
}
