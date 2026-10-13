// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// Robinhood Chain mainnet (4663) addresses, verified on-chain
/// (SPEC 3.1 and 3.2a). Stages: 0 design, 1 memory, 2 fab, 3 equipment, 4 power.
library RobinhoodChain {
    uint256 internal constant CHAIN_ID = 4663;

    address internal constant UNISWAP_V2_FACTORY = 0x8bcEaA40B9AcdfAedF85AdF4FF01F5Ad6517937f;
    address internal constant UNISWAP_V2_ROUTER = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    /// UNCX Liquidity Lockers V2 for Uniswap v2 (docs.uncx.network, Liquidity Lockers V2), checked on
    /// chain: uniswapFactory() is UNISWAP_V2_FACTORY, and lockLPToken matches IUniswapV2Locker.
    /// Country codes are UNCX's own index into its COUNTRY_LIST (0 to 252 here), not ISO numbers.
    address internal constant UNCX_V2_LOCKER = 0xB560307e7e02a58dBB03562aaB32700255140E37;
    /// Sablier Lockup v4.0 (Sablier's deployment list; checked on chain with a stream created on a fork).
    address internal constant SABLIER_LOCKUP = 0x548129a58bC230549DF7F9e33f27E77F6779ff0f;
    /// Uniswap v3 SwapRouter02, where the stock tokens trade: the Reserve's swap target.
    address internal constant UNISWAP_V3_SWAP_ROUTER_02 = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address internal constant UNISWAP_V3_QUOTER_V2 = 0x33e885eD0Ec9bF04EcfB19341582aADCb4c8A9E7;
    address internal constant WETH = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address internal constant ETH_USD_FEED = 0x78F3556b67E17Df817D51Ef5a990cDaF09E8d3A9;
    /// USDG, Global Dollar (6 decimals; name, symbol and decimals read on chain).
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;

    /// Uniswap v4 (Uniswap's v4 deployment list, Robinhood Chain 4663), checked on chain: the
    /// PositionManager, StateView and V4Quoter each read back this PoolManager, the PositionManager
    /// reads back Permit2 and WETH, and Permit2's domain separator is the one for chain 4663.
    address internal constant UNISWAP_V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address internal constant UNISWAP_V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address internal constant UNISWAP_V4_STATE_VIEW = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address internal constant UNISWAP_V4_QUOTER = 0x8Dc178eFB8111BB0973Dd9d722ebeFF267c98F94;
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    address internal constant NVDA = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address internal constant NVDA_USD = 0x379EC4f7C378F34a1B47E4F3cbeBCbAC3E8E9F15;
    address internal constant AMD = 0x86923f96303D656E4aa86D9d42D1e57ad2023fdC;
    address internal constant AMD_USD = 0x943A29E7ae51A4798823ca9eEd2ed533B2A22C72;
    address internal constant MU = 0xfF080c8ce2E5feadaCa0Da81314Ae59D232d4afD;
    address internal constant MU_USD = 0x425EEFdCf05ed6526C3cE61Af99429A228a6d596;
    address internal constant SNDK = 0xB90A19fF0Af67f7779afF50A882A9CfF42446400;
    address internal constant SNDK_USD = 0xfb133Fa4B7b385802B693a293606682Df47109A3;
    address internal constant TSM = 0x58FfE4a942d3885bAa22D7520691F611EF09e7AA;
    address internal constant TSM_USD = 0x874cF94aa8eC88Fd9560094dD065f2fB3E41Fc2F;
    address internal constant INTC = 0xc72b96e0E48ecd4DC75E1e45396e26300BC39681;
    address internal constant INTC_USD = 0x3f390C5C24628Ac7C489515402235FeAD71D1913;
    address internal constant ASML = 0x47F93d52cBeC7C6D2CfC080e154002370a60dAEA;
    address internal constant ASML_USD = 0xB4106147E8cce40b7d46124090d373A71b70f87D;
    /// The beacon every stock token above runs behind; the tokens read their paused state from it
    /// (SPEC 3.2a, checked on-chain).
    address internal constant STOCK_BEACON = 0xe10b6f6B275de231345c20D14Ab812db62151b00;

    struct Asset {
        address token;
        address feed;
        uint8 stage;
    }

    /// The seven eligible stock tokens with a live Chainlink feed (SPEC 3.2a).
    function assets() internal pure returns (Asset[7] memory list) {
        list[0] = Asset({token: NVDA, feed: NVDA_USD, stage: 0});
        list[1] = Asset({token: AMD, feed: AMD_USD, stage: 0});
        list[2] = Asset({token: MU, feed: MU_USD, stage: 1});
        list[3] = Asset({token: SNDK, feed: SNDK_USD, stage: 1});
        list[4] = Asset({token: TSM, feed: TSM_USD, stage: 2});
        list[5] = Asset({token: INTC, feed: INTC_USD, stage: 2});
        list[6] = Asset({token: ASML, feed: ASML_USD, stage: 3});
    }
}
