// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";

/// A Uniswap v2 stand-in at a fixed price of 300,000,000 tokens per ETH. Like Router02,
/// sells measure what reached the pair against its synced reserve, so fee-on-transfer
/// tokens and swaps nested inside a transfer settle exactly. The fork tests cover the
/// real Router02.
contract MockUniswapV2Pair {
    address public immutable router;
    address public immutable token0;
    address public immutable token1;
    mapping(address => uint256) public reserveOf;

    constructor(address router_, address tokenA, address tokenB) {
        router = router_;
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    /// As Uniswap's: the synced balances, zero until liquidity is added.
    function getReserves() external view returns (uint112, uint112, uint32) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return (uint112(reserveOf[token0]), uint112(reserveOf[token1]), 0);
    }

    modifier onlyRouter() {
        require(msg.sender == router, "MockPair: router only");
        _;
    }

    function pay(address token, address to, uint256 amount) external onlyRouter {
        require(IERC20(token).transfer(to, amount), "MockPair: transfer");
        reserveOf[token] = IERC20(token).balanceOf(address(this));
    }

    function sync(address token) external onlyRouter {
        reserveOf[token] = IERC20(token).balanceOf(address(this));
    }
}

contract MockUniswapV2Factory {
    address public router;
    mapping(address => mapping(address => address)) public getPair;

    function setRouter(address router_) external {
        require(router == address(0), "MockFactory: router set");
        router = router_;
    }

    function createPair(address tokenA, address tokenB) external returns (address pair) {
        require(getPair[tokenA][tokenB] == address(0), "MockFactory: exists");
        pair = address(new MockUniswapV2Pair(router, tokenA, tokenB));
        getPair[tokenA][tokenB] = pair;
        getPair[tokenB][tokenA] = pair;
    }
}

contract MockUniswapV2Router {
    uint256 public constant TOKENS_PER_ETH = 300_000_000;

    address public immutable factory;
    address public immutable WETH;
    /// Swaps sent by this address revert (to test a failing tax swap).
    address public failFor;

    constructor(address factory_, address weth_) {
        factory = factory_;
        WETH = weth_;
    }

    receive() external payable {}

    function setFailFor(address caller) external {
        failFor = caller;
    }

    /// Wraps the sent ETH into WETH and moves both sides into the pair, like the real Router02,
    /// so the pair carries real launch liquidity (as the launch does).
    function addLiquidityETH(address token, uint256 amountTokenDesired, uint256, uint256, address, uint256)
        external
        payable
        returns (uint256, uint256, uint256)
    {
        address pair = MockUniswapV2Factory(factory).getPair(token, WETH);
        require(IERC20(token).transferFrom(msg.sender, pair, amountTokenDesired), "MockRouter: transferFrom");
        IWETH(WETH).deposit{value: msg.value}();
        require(IERC20(WETH).transfer(pair, msg.value), "MockRouter: WETH transfer");
        MockUniswapV2Pair(pair).sync(token);
        MockUniswapV2Pair(pair).sync(WETH);
        return (amountTokenDesired, msg.value, 0);
    }

    function swapExactTokensForETHSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external {
        require(msg.sender != failFor, "MockRouter: forced failure");
        require(path.length == 2 && path[1] == WETH, "MockRouter: path");
        address pair = MockUniswapV2Factory(factory).getPair(path[0], WETH);
        require(IERC20(path[0]).transferFrom(msg.sender, pair, amountIn), "MockRouter: transferFrom");
        uint256 got = IERC20(path[0]).balanceOf(pair) - MockUniswapV2Pair(pair).reserveOf(path[0]);
        MockUniswapV2Pair(pair).sync(path[0]);
        uint256 ethOut = got / TOKENS_PER_ETH;
        require(ethOut >= amountOutMin, "MockRouter: slippage");
        (bool ok,) = to.call{value: ethOut}("");
        require(ok, "MockRouter: ETH send");
    }

    function swapExactETHForTokensSupportingFeeOnTransferTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256
    ) external payable {
        require(path.length == 2 && path[0] == WETH, "MockRouter: path");
        address pair = MockUniswapV2Factory(factory).getPair(WETH, path[1]);
        uint256 before = IERC20(path[1]).balanceOf(to);
        MockUniswapV2Pair(pair).pay(path[1], to, msg.value * TOKENS_PER_ETH);
        require(IERC20(path[1]).balanceOf(to) - before >= amountOutMin, "MockRouter: slippage");
    }
}
