// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IWETH} from "../../../src/interfaces/IWETH.sol";
import {ISiliconFeed} from "../../../src/silicon/interfaces/ISiliconFeed.sol";
import {IKyznUsdOracle} from "../../../src/silicon/interfaces/IKyznUsdOracle.sol";

/// An ERC-20 with any decimals and open minting: $KYZN (18) and USDG (6) stand-ins.
contract MockToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory symbol_, uint8 decimals_) ERC20(symbol_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// KyznUsdOracle stand-in: a settable $KYZN price, or unavailable (as when the TWAP has no
/// observation in range or ETH/USD is stale). Counts update() calls.
contract MockKyznOracle is IKyznUsdOracle {
    uint256 public usdPerKyzn;
    bool public unavailable;
    uint256 public updates;

    error OracleUnavailable();

    constructor(uint256 usdPerKyzn_) {
        usdPerKyzn = usdPerKyzn_;
    }

    function set(uint256 usdPerKyzn_) external {
        usdPerKyzn = usdPerKyzn_;
    }

    function setUnavailable(bool value) external {
        unavailable = value;
    }

    function update() external returns (bool) {
        ++updates;
        return true;
    }

    function price() external view returns (uint256) {
        if (unavailable) revert OracleUnavailable();
        return usdPerKyzn;
    }
}

/// SiliconFeed stand-in: a settable final price and report time, fresh for maxAge seconds, an
/// optional price in its dispute window, a reporter, guardian and methodology already set, and a
/// readiness (not ready until setReady) and liquidation freshness (fresh until set otherwise) of
/// their own. Counts sync() calls.
contract MockSiliconFeed is ISiliconFeed {
    uint256 public price;
    uint256 public updatedAt;
    uint256 public immutable maxAge;
    uint256 public pending;
    address public reporter = address(0xBEEF);
    address public guardian = address(0xCAFE);
    bytes32 public methodologyHash = keccak256("methodology");
    bool public freshForLiquidation = true;
    bool public isReady;
    /// How many times sync() has been called.
    uint256 public syncs;

    constructor(uint256 price_, uint256 maxAge_) {
        price = price_;
        updatedAt = block.timestamp;
        maxAge = maxAge_;
    }

    /// A new final price, reported now.
    function set(uint256 price_) external {
        price = price_;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 updatedAt_) external {
        updatedAt = updatedAt_;
    }

    /// A price waiting in its dispute window (0: none).
    function setPending(uint256 price_) external {
        pending = price_;
    }

    function setRoles(address reporter_, address guardian_, bytes32 methodologyHash_) external {
        reporter = reporter_;
        guardian = guardian_;
        methodologyHash = methodologyHash_;
    }

    /// Whether the feed may back an open market (independent of the roles above).
    function setReady(bool value) external {
        isReady = value;
    }

    /// Whether a liquidation may use the price (independent of its age).
    function setFreshForLiquidation(bool value) external {
        freshForLiquidation = value;
    }

    function latestPrice() external view returns (uint256, uint256) {
        return (price, updatedAt);
    }

    function isFresh() external view returns (bool) {
        return updatedAt != 0 && block.timestamp <= updatedAt + maxAge;
    }

    function isFreshForLiquidation() external view returns (bool) {
        return freshForLiquidation;
    }

    function ready() external view returns (bool) {
        return isReady;
    }

    function sync() external {
        ++syncs;
    }

    function pendingPrice() external view returns (uint256, uint256, bytes32, uint256) {
        if (pending == 0) return (0, 0, bytes32(0), 0);
        return (pending, block.timestamp, keccak256("sources"), block.timestamp + 1);
    }
}

/// A swap target for SiliconFeeRouter tests: pulls the token in and pays a set amount of ETH,
/// as WETH or native.
contract MockSwapTarget {
    using SafeERC20 for IERC20;

    IWETH public immutable weth;

    constructor(IWETH weth_) {
        weth = weth_;
    }

    receive() external payable {}

    /// Pulls `amountIn` of `tokenIn` from the caller and pays `ethOut`, as WETH when `asWeth`.
    function swap(IERC20 tokenIn, uint256 amountIn, uint256 ethOut, bool asWeth) external {
        tokenIn.safeTransferFrom(msg.sender, address(this), amountIn);
        if (asWeth) {
            weth.deposit{value: ethOut}();
            IERC20(address(weth)).safeTransfer(msg.sender, ethOut);
        } else {
            (bool ok,) = msg.sender.call{value: ethOut}("");
            require(ok, "MockSwapTarget: ETH send");
        }
    }
}

/// Accepts ETH and counts it: a stand-in recipient for the Reserve or Staking.
contract EthSink {
    uint256 public received;

    receive() external payable {
        received += msg.value;
    }
}

/// A collateral token that calls back into a target on every transfer out of the vault, as a
/// hook token would: the reentrancy guard must stop the inner call.
contract CallbackToken is ERC20 {
    address public vault;
    bytes public callbackData;
    bool public callbackReverted;
    bytes public callbackError;

    constructor() ERC20("HOOK", "HOOK") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function arm(address vault_, bytes calldata data) external {
        vault = vault_;
        callbackData = data;
    }

    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (from == vault && vault != address(0) && callbackData.length != 0) {
            bytes memory data = callbackData;
            delete callbackData;
            (bool ok, bytes memory err) = vault.call(data);
            callbackReverted = !ok;
            callbackError = err;
        }
    }
}

/// A Chainlink-style feed with rounds, for StockIndexFeed tests: set() starts a new round.
contract MockRoundFeed {
    uint8 public immutable decimals;
    uint80 public latestRound;
    mapping(uint80 => int256) public answers;
    mapping(uint80 => uint256) public times;
    bool public previousUnreadable;

    constructor(uint8 decimals_, int256 answer) {
        decimals = decimals_;
        set(answer);
    }

    function set(int256 answer) public {
        latestRound++;
        answers[latestRound] = answer;
        times[latestRound] = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        times[latestRound] = t;
    }

    function setPreviousUnreadable(bool v) external {
        previousUnreadable = v;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (latestRound, answers[latestRound], times[latestRound], times[latestRound], latestRound);
    }

    function getRoundData(uint80 roundId) external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!previousUnreadable && roundId != 0 && roundId <= latestRound, "no round");
        return (roundId, answers[roundId], times[roundId], times[roundId], roundId);
    }
}
