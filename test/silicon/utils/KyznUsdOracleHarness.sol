// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {KyznUsdOracle} from "../../../src/silicon/KyznUsdOracle.sol";
import {IUniswapV2PairTwap} from "../../../src/silicon/interfaces/IUniswapV2PairTwap.sol";

/// KyznUsdOracle with its observation search exposed beside the linear walk the search replaced,
/// kept verbatim as the reference, and a way to write any ring of observations directly.
contract KyznUsdOracleHarness is KyznUsdOracle {
    constructor(IUniswapV2PairTwap pair_, address kyzn_, address ethUsdFeed_, uint256 shortWindow_, uint256 longWindow_)
        KyznUsdOracle(pair_, kyzn_, ethUsdFeed_, shortWindow_, longWindow_)
    {}

    /// The binary search price() runs.
    function findAtLeast(uint256 age) external view returns (uint256 timestamp, uint256 cumulative) {
        Observation memory o = _findAtLeast(age);
        return (o.timestamp, o.cumulative);
    }

    /// The linear walk it replaced.
    function findAtLeastLinear(uint256 age) external view returns (uint256 timestamp, uint256 cumulative) {
        Observation memory o = _findAtLeastLinear(age);
        return (o.timestamp, o.cumulative);
    }

    /// Replaces the history: `recorded` observations made, the held ones (the newest
    /// min(recorded, ringSize)) at `timestamps`, newest first, each with a distinct cumulative.
    /// Every slot not held gets a junk observation a search must never return.
    function setHistory(uint256 recorded, uint256[] calldata timestamps) external {
        uint256 count = Math.min(recorded, ringSize);
        require(recorded != 0 && timestamps.length == count, "history");
        for (uint256 slot; slot < ringSize; ++slot) {
            _ring[slot] = Observation({timestamp: type(uint256).max - slot, cumulative: type(uint256).max - slot});
        }
        _recorded = recorded;
        for (uint256 k; k < count; ++k) {
            _ring[(recorded - 1 - k) % ringSize] = Observation({timestamp: timestamps[k], cumulative: 1_000 + k});
        }
    }

    /// KyznUsdOracle._findAtLeast before the binary search (commit 857d63a), verbatim.
    function _findAtLeastLinear(uint256 age) private view returns (Observation memory) {
        uint256 n = _recorded;
        uint256 count = Math.min(n, ringSize);
        uint256 timestamp;
        for (uint256 k; k < count; ++k) {
            Observation storage o = _ring[(n - 1 - k) % ringSize];
            timestamp = o.timestamp;
            if (block.timestamp - timestamp >= age) return o;
        }
        revert TwapNotReady(timestamp + age);
    }
}
