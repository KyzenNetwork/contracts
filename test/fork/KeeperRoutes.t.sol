// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Test, console2} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Reserve} from "../../src/Reserve.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IKyzn} from "../../src/interfaces/IKyzn.sol";
import {IRotationState} from "../../src/interfaces/IRotationState.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {RobinhoodChain as RH} from "../../script/RobinhoodChain.sol";

interface IQuoterV2 {
    function quoteExactInput(bytes memory path, uint256 amountIn)
        external
        returns (uint256 amountOut, uint160[] memory, uint32[] memory, uint256);
}

interface ISwapRouter02 {
    struct ExactInputParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);
}

/// The reads the Reserve makes of the token here: its pair and Staking (never swap targets). The
/// assets are listed by the Reserve's constructor, as in the launch.
contract TokenReads {
    address public pair = address(0xBEEF);
    address public staking = address(0x5AFE);
}

/// Before the first rotation (purchases do not read it; sales would).
contract NoRotationYet is IRotationState {
    function hasExecuted() external pure returns (bool) {
        return false;
    }
}

/// The keeper's purchases (SPEC 3.2) against Robinhood Chain mainnet's real Uniswap v3 pools, in a
/// Reserve configured as the launch configures it: the seven stock tokens and their feeds, the
/// keeper, and SwapRouter02 as its swap target once the 24-hour delay has passed. As
/// services/gateway's keeper does, each purchase halves from a slice until the pool quotes at least
/// 99% of the Chainlink-implied amount, sends 0.5% below the quote as the minimum, and skips the
/// token when no size reaches 99% (through a 1% fee pool it rarely can). The Reserve then enforces
/// its own 98.5% bound. NVDA and AMD, the launch holdings with the deepest pools, must be bought.
///
/// One test per token, run one at a time (`--match-test`): the public node keeps about 20 minutes
/// of history, and one run over all seven through the serial forwarder outlives it. The feeds are
/// held at their real answers, made fresh after the target's delay (a fork cannot move Chainlink
/// forward).
contract KeeperRoutesForkTest is Test {
    address internal constant USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint256 internal constant SLICE = 0.02 ether;
    uint256 internal constant MIN_SLICE = 0.001 ether;
    string[7] internal SYMBOLS = ["NVDA", "AMD", "MU", "SNDK", "TSM", "INTC", "ASML"];
    address internal keeper = makeAddr("keeper");
    Reserve internal reserve;
    IQuoterV2 internal quoter = IQuoterV2(RH.UNISWAP_V3_QUOTER_V2);
    address internal router = RH.UNISWAP_V3_SWAP_ROUTER_02;
    int256 internal ethAnswer;
    int256[7] internal answers;

    function setUp() public {
        vm.createSelectFork("robinhood");
        RH.Asset[7] memory list = RH.assets();
        Reserve.AssetConfig[] memory initial = new Reserve.AssetConfig[](7);
        for (uint256 i; i < 7; ++i) {
            initial[i] = Reserve.AssetConfig({token: list[i].token, feed: list[i].feed, stage: list[i].stage});
        }
        reserve = new Reserve(IKyzn(address(new TokenReads())), IWETH(RH.WETH), RH.ETH_USD_FEED, new NoRotationYet(), initial);
        reserve.setKeeper(keeper);
        reserve.queueTarget(router, true);
        vm.deal(address(reserve), 1 ether);

        for (uint256 i; i < 7; ++i) {
            (, answers[i],,,) = IAggregatorV3(list[i].feed).latestRoundData();
        }
        (, ethAnswer,,,) = IAggregatorV3(RH.ETH_USD_FEED).latestRoundData();
        vm.warp(_nextSession(block.timestamp + 24 hours + 1));
        for (uint256 i; i < 7; ++i) {
            _holdFresh(list[i].feed, answers[i]);
        }
        _holdFresh(RH.ETH_USD_FEED, ethAnswer);
        assertTrue(reserve.isTargetAllowed(router));
    }

    function test_NVDA_direct_at_0_05_percent() public {
        _keeperBuys(0, _path2(RH.WETH, 500, RH.NVDA), true);
    }

    function test_AMD_through_USDG() public {
        _keeperBuys(1, _path3(RH.WETH, 100, USDG, 3000, RH.AMD), true);
    }

    function test_MU_direct_at_1_percent() public {
        _keeperBuys(2, _path2(RH.WETH, 10000, RH.MU), false);
    }

    function test_SNDK_direct_at_0_3_percent() public {
        _keeperBuys(3, _path2(RH.WETH, 3000, RH.SNDK), false);
    }

    function test_TSM_direct_at_0_3_percent() public {
        _keeperBuys(4, _path2(RH.WETH, 3000, RH.TSM), false);
    }

    function test_INTC_direct_at_0_3_percent() public {
        _keeperBuys(5, _path2(RH.WETH, 3000, RH.INTC), false);
    }

    /// ASML has no WETH pool: through USDG, at 0.3% (the shallower pool), else at 1%.
    function test_ASML_through_USDG() public {
        if (!_keeperBuys(6, _path3(RH.WETH, 100, USDG, 3000, RH.ASML), false)) {
            _keeperBuys(6, _path3(RH.WETH, 100, USDG, 10000, RH.ASML), false);
        }
    }

    /// The keeper's purchase of asset `i` through `path`: true if a size met the 99% floor and the
    /// Reserve bought it; false if the keeper skips the token.
    function _keeperBuys(uint256 i, bytes memory path, bool required) internal returns (bool) {
        address token = RH.assets()[i].token;
        uint256 size = SLICE;
        uint256 out;
        uint256 implied;
        for (; size >= MIN_SLICE; size /= 2) {
            out = _quote(path, size);
            implied = size * uint256(ethAnswer) / uint256(answers[i]);
            if (out * 10_000 >= implied * 9_900) break;
        }
        if (size < MIN_SLICE) {
            console2.log(SYMBOLS[i], "skipped; best quote in basis points of the implied amount:", out * 10_000 / implied);
            assertFalse(required, "no size within 99% of the Chainlink price");
            return false;
        }
        uint256 minOut = out * 9_950 / 10_000;
        bytes memory data = abi.encodeCall(
            ISwapRouter02.exactInput,
            (ISwapRouter02.ExactInputParams({path: path, recipient: address(reserve), amountIn: size, amountOutMinimum: minOut}))
        );
        uint256 before = IERC20(token).balanceOf(address(reserve));
        uint256 gasBefore = gasleft();
        vm.prank(keeper);
        uint256 received = reserve.buy(token, router, data, size, minOut);
        uint256 gasUsed = gasBefore - gasleft();
        assertEq(IERC20(token).balanceOf(address(reserve)) - before, received);
        assertGe(received, minOut);
        assertGe(received * 10_000, implied * 9_850, "inside the Reserve's own bound");
        console2.log(SYMBOLS[i], "bought; wei spent:", size);
        console2.log("  received in basis points of the implied amount:", received * 10_000 / implied);
        console2.log("  gas:", gasUsed);
        return true;
    }

    function _quote(bytes memory path, uint256 amountIn) internal returns (uint256 out) {
        try quoter.quoteExactInput(path, amountIn) returns (uint256 o, uint160[] memory, uint32[] memory, uint256) {
            out = o;
        } catch {}
    }

    function _holdFresh(address feed, int256 answer) internal {
        vm.mockCall(
            feed,
            abi.encodeWithSelector(IAggregatorV3.latestRoundData.selector),
            abi.encode(uint80(1), answer, block.timestamp, block.timestamp, uint80(1))
        );
    }

    /// The next weekday 15:00 UTC at or after `t`: inside the Reserve's window and the NYSE session.
    function _nextSession(uint256 t) internal pure returns (uint256 opensAt) {
        for (uint256 day = t / 1 days;; ++day) {
            opensAt = day * 1 days + 15 hours;
            uint256 weekday = (day + 4) % 7; // 0 = Sunday
            if (opensAt >= t && weekday >= 1 && weekday <= 5) return opensAt;
        }
    }

    function _path2(address a, uint24 f, address b) internal pure returns (bytes memory) {
        return abi.encodePacked(a, f, b);
    }

    function _path3(address a, uint24 f1, address b, uint24 f2, address c) internal pure returns (bytes memory) {
        return abi.encodePacked(a, f1, b, f2, c);
    }
}
