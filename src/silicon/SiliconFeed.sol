// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ISiliconFeed} from "./interfaces/ISiliconFeed.sol";

/// @title Kyzen Network Silicon price feed (SPEC 3.5)
/// @notice One market's USD price, 18 decimals. The reporter the owner names posts a price with
/// a hash of the sources it was taken from. A posted price becomes the market price only once
/// its dispute window has passed, unless the guardian the owner names rejects it within the
/// window. One price waits at a time. GPU-hour feeds post hourly; the attested feeds (DRAM, HBM4,
/// CoWoS) as their published methodology says.
///
/// A price that has passed its window is final whether or not anyone has called finalize():
/// latestPrice() reads it at once, and the next report() or finalize() records it. A price's age
/// runs from when it was reported, so the maximum age is longer than the dispute window.
contract SiliconFeed is Ownable2Step, ISiliconFeed {
    /// A posted price, its report time and the hash of its sources.
    struct Report {
        uint256 price;
        uint256 reportedAt;
        bytes32 sourcesHash;
    }

    /// What the feed prices, for example "H100-HR / USD".
    string public description;
    /// Seconds a posted price waits, open to rejection, before it is final.
    uint256 public immutable disputeWindow;
    /// Seconds after its report that a final price stays fresh.
    uint256 public immutable maxAge;

    /// The address that posts prices (none until the owner sets it).
    address public reporter;
    /// The address that may reject a posted price within its dispute window (none until set).
    address public guardian;
    /// Where the published methodology lives (sources, cadence, aggregation, dispute process).
    string public methodologyURI;
    /// Hash of the published methodology document.
    bytes32 public methodologyHash;

    Report private _latest;
    Report private _pending; // reportedAt is 0 when nothing is pending

    /// A price was posted; it is final at `finalizesAt` unless the guardian rejects it before then.
    event PriceReported(uint256 price, bytes32 sourcesHash, uint256 finalizesAt);
    /// A posted price became the latest price.
    event PriceFinalized(uint256 price, uint256 reportedAt, bytes32 sourcesHash);
    /// The guardian rejected a posted price within its dispute window.
    event PriceRejected(uint256 price, uint256 reportedAt, bytes32 sourcesHash);
    /// The owner named the reporter (zero: no one may report).
    event ReporterSet(address indexed reporter);
    /// The owner named the guardian (zero: no one may reject).
    event GuardianSet(address indexed guardian);
    /// The owner published the methodology's location and hash.
    event MethodologySet(string uri, bytes32 hash);

    /// The dispute window is zero.
    error BadDisputeWindow();
    /// The maximum age is not longer than the dispute window, so no price would ever be fresh.
    error BadMaxAge();
    /// The caller is not the reporter.
    error NotReporter();
    /// The caller is not the guardian.
    error NotGuardian();
    /// A price must be above zero.
    error ZeroPrice();
    /// A report must name the hash of its sources.
    error NoSourcesHash();
    /// A posted price is still in its dispute window, until `finalizesAt`.
    error ReportPending(uint256 finalizesAt);
    /// No price is waiting in its dispute window.
    error NothingPending();
    /// The pending price cannot be finalized before `finalizesAt`.
    error DisputeWindowOpen(uint256 finalizesAt);
    /// The pending price became final at `finalizesAt` and can no longer be rejected.
    error DisputeWindowClosed(uint256 finalizesAt);

    /// `description_` names what is priced, for example "H100-HR / USD". A price stays fresh
    /// for `maxAge_` seconds after its report, so `maxAge_` must exceed `disputeWindow_`.
    constructor(string memory description_, uint256 disputeWindow_, uint256 maxAge_) Ownable(msg.sender) {
        if (disputeWindow_ == 0) revert BadDisputeWindow();
        if (maxAge_ <= disputeWindow_) revert BadMaxAge();
        description = description_;
        disputeWindow = disputeWindow_;
        maxAge = maxAge_;
    }

    // ---------------------------------------------------------------- owner

    /// Names the reporter; zero stops reports.
    function setReporter(address reporter_) external onlyOwner {
        reporter = reporter_;
        emit ReporterSet(reporter_);
    }

    /// Names the guardian; zero leaves posted prices unchallengeable.
    function setGuardian(address guardian_) external onlyOwner {
        guardian = guardian_;
        emit GuardianSet(guardian_);
    }

    /// Publishes the methodology's location and hash (SPEC 3.7: methodology before markets open).
    function setMethodology(string calldata uri, bytes32 hash) external onlyOwner {
        methodologyURI = uri;
        methodologyHash = hash;
        emit MethodologySet(uri, hash);
    }

    // ---------------------------------------------------------------- prices

    /// Reporter only. Posts `price` (USD, 18 decimals) with the hash of its sources. A pending
    /// price whose window has passed is finalized first; one still in its window blocks the report.
    function report(uint256 price, bytes32 sourcesHash) external {
        if (msg.sender != reporter) revert NotReporter();
        if (price == 0) revert ZeroPrice();
        if (sourcesHash == bytes32(0)) revert NoSourcesHash();
        if (_pending.reportedAt != 0) {
            uint256 finalizesAt = _pending.reportedAt + disputeWindow;
            if (block.timestamp < finalizesAt) revert ReportPending(finalizesAt);
            _finalize();
        }
        _pending = Report({price: price, reportedAt: block.timestamp, sourcesHash: sourcesHash});
        emit PriceReported(price, sourcesHash, block.timestamp + disputeWindow);
    }

    /// Anyone, once the pending price's dispute window has passed: records it as the latest price.
    function finalize() external {
        if (_pending.reportedAt == 0) revert NothingPending();
        uint256 finalizesAt = _pending.reportedAt + disputeWindow;
        if (block.timestamp < finalizesAt) revert DisputeWindowOpen(finalizesAt);
        _finalize();
    }

    /// Guardian only, within the dispute window: drops the pending price. The reporter may then
    /// post again at once.
    function reject() external {
        if (msg.sender != guardian) revert NotGuardian();
        Report memory p = _pending;
        if (p.reportedAt == 0) revert NothingPending();
        uint256 finalizesAt = p.reportedAt + disputeWindow;
        if (block.timestamp >= finalizesAt) revert DisputeWindowClosed(finalizesAt);
        delete _pending;
        emit PriceRejected(p.price, p.reportedAt, p.sourcesHash);
    }

    // ---------------------------------------------------------------- views

    /// Prices are USD with 18 decimals.
    function decimals() external pure returns (uint8) {
        return 18;
    }

    /// The latest final price and its report time, including a pending price whose window has
    /// passed; (0, 0) before the first price is final.
    function latestPrice() public view returns (uint256 price, uint256 updatedAt) {
        Report storage r = _pendingIsFinal() ? _pending : _latest;
        return (r.price, r.reportedAt);
    }

    /// True while a final price exists and is at most maxAge seconds past its report.
    function isFresh() public view returns (bool) {
        (, uint256 updatedAt) = latestPrice();
        return updatedAt != 0 && block.timestamp <= updatedAt + maxAge;
    }

    /// True while a liquidation may use the price: the same as isFresh() for an attested feed.
    function isFreshForLiquidation() external view returns (bool) {
        return isFresh();
    }

    /// True once the reporter, the guardian and the methodology are all set (SPEC 3.7: methodology
    /// before markets open), so a market may open on this feed.
    function ready() external view returns (bool) {
        return reporter != address(0) && guardian != address(0) && methodologyHash != bytes32(0);
    }

    /// Does nothing: an attested feed has no rounds to check. The vault calls it before reading
    /// freshness, as it does for every feed.
    function sync() external pure {}

    /// The price waiting in its dispute window, if any (all zero when none is).
    function pendingPrice()
        external
        view
        returns (uint256 price, uint256 reportedAt, bytes32 sourcesHash, uint256 finalizesAt)
    {
        if (_pending.reportedAt == 0 || _pendingIsFinal()) return (0, 0, bytes32(0), 0);
        Report memory p = _pending;
        return (p.price, p.reportedAt, p.sourcesHash, p.reportedAt + disputeWindow);
    }

    /// The hash of the sources behind the latest final price.
    function latestSourcesHash() external view returns (bytes32) {
        return _pendingIsFinal() ? _pending.sourcesHash : _latest.sourcesHash;
    }

    // ---------------------------------------------------------------- internals

    function _pendingIsFinal() private view returns (bool) {
        uint256 reportedAt = _pending.reportedAt;
        return reportedAt != 0 && block.timestamp >= reportedAt + disputeWindow;
    }

    function _finalize() private {
        Report memory p = _pending;
        _latest = p;
        delete _pending;
        emit PriceFinalized(p.price, p.reportedAt, p.sourcesHash);
    }
}
