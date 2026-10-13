// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IAggregatorV3} from "../interfaces/IAggregatorV3.sol";

/// Chainlink reads and the purchase window shared by the Reserve and Staking (SPEC 3.2).
library PriceLib {
    /// 13:30 UTC, the U.S. open in summer time.
    uint256 internal constant WINDOW_OPEN = 13 hours + 30 minutes;
    /// 21:00 UTC, the U.S. close in winter time. The window ends before this second.
    uint256 internal constant WINDOW_CLOSE = 21 hours;
    /// Gas for one feed read. A feed that needs more, reverts, or answers with fewer than the
    /// five words (160 bytes) latestRoundData owes is unreadable to tryLatest.
    uint256 internal constant FEED_GAS = 100_000;

    error StalePrice(address feed);
    error BadPrice(address feed);

    /// Monday to Friday, 13:30 to 21:00 UTC. 1 January 1970 was a Thursday.
    function inPurchaseWindow(uint256 timestamp) internal pure returns (bool) {
        uint256 weekday = (timestamp / 1 days + 4) % 7; // 0 = Sunday
        uint256 second = timestamp % 1 days;
        return weekday >= 1 && weekday <= 5 && second >= WINDOW_OPEN && second < WINDOW_CLOSE;
    }

    /// The latest answer scaled to 18 decimals, and when it was updated. Reverts on a non-positive answer.
    function latest(address feed, uint8 feedDecimals) internal view returns (uint256 price, uint256 updatedAt) {
        (, int256 answer,, uint256 updated,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert BadPrice(feed);
        // answer > 0 was checked above, so the cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        price = uint256(answer) * 10 ** (18 - feedDecimals);
        updatedAt = updated;
    }

    /// As latest(), whatever the answer's age, but never reverts: ok is false when the feed
    /// needs more than FEED_GAS gas, the call reverts, the answer is fewer than 160 bytes, is
    /// not positive, or scaling it overflows. Reads with a gas-capped low-level staticcall and
    /// decodes the answer and its update time by hand, because try/catch cannot be relied on
    /// here: it only catches the external call reverting, not the ABI decode Solidity runs
    /// afterwards to match latestRoundData's five return values, so a malformed but
    /// non-reverting answer (for example a feed that answers with too few bytes) would still
    /// revert the caller. Only the answer and updatedAt words are read, so stray bits in the
    /// unused roundId and answeredInRound words, which the ABI decode would reject, are ignored.
    function tryLatest(address feed, uint8 feedDecimals)
        internal
        view
        returns (bool ok, uint256 price, uint256 updatedAt)
    {
        bytes memory data = abi.encodeCall(IAggregatorV3.latestRoundData, ());
        uint256 gasLimit = FEED_GAS;
        int256 answer;
        uint256 updated;
        assembly ("memory-safe") {
            ok := staticcall(gasLimit, feed, add(data, 0x20), mload(data), 0x00, 0x00)
            ok := and(ok, gt(returndatasize(), 0x9f))
            if ok {
                returndatacopy(0x00, 0x20, 0x20) // answer: the second of the five words
                returndatacopy(0x20, 0x60, 0x20) // updatedAt: the fourth of the five words
                answer := mload(0x00)
                updated := mload(0x20)
            }
        }
        if (!ok || answer <= 0) return (false, 0, 0);
        // answer > 0 was checked above, so the cast cannot wrap.
        // forge-lint: disable-next-line(unsafe-typecast)
        (ok, price) = Math.tryMul(uint256(answer), 10 ** (18 - feedDecimals));
        if (ok) updatedAt = updated;
    }

    /// As latest(), and reverts unless the answer is at most maxAge old.
    function fresh(address feed, uint8 feedDecimals, uint256 maxAge) internal view returns (uint256 price) {
        uint256 updatedAt;
        (price, updatedAt) = latest(feed, feedDecimals);
        if (updatedAt + maxAge < block.timestamp) revert StalePrice(feed);
    }
}
