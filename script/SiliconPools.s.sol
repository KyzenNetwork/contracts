// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {ISiliconFeed} from "../src/silicon/interfaces/ISiliconFeed.sol";
import {RobinhoodChain as RH} from "./RobinhoodChain.sol";
import {SiliconMainnetTerms as Terms} from "./SiliconMainnet.sol";
import {SiliconPoolSeed as Seed} from "./lib/SiliconPoolSeed.sol";
import {V4PoolMath as M} from "./lib/V4PoolMath.sol";
import {V4PriceMover} from "./lib/V4PriceMover.sol";
import {IV4PoolManager, IV4PositionManager, IV4StateView, PoolKey} from "./interfaces/IUniswapV4.sol";

/// The Uniswap v4 pools of the four Silicon stock indices against USDG on Robinhood Chain mainnet
/// (SPEC 3.5, Venue), each initialised at its index's price and seeded with the owner's position:
/// a USDG-only bid below the index price (KYZEN_POOL_MODE=bid, the owner's decision in SPEC 3.5), or
/// a two-sided position of synth and USDG (KYZEN_POOL_MODE=two-sided).
/// Run by the owner after minting, with the owner wallet's key given at run time; nothing here
/// holds a key, an amount or a fee tier. It refuses any broadcaster other than the owner wallet
/// (SiliconMainnetTerms.OWNER). The seed amounts are the owner's decision (SPEC 3.5: "amount and
/// source to decide"), and so are the fee tier, the tick spacing and the range: a pool's id is
/// its key, so a pool made with the wrong tier stays on chain for good.
///
/// For each of kDESIGN, kMEMORY, kFAB and kEQUIP that has amounts in the environment it:
///   1. reads the synth and its index feed from deployments/4663.json, "silicon.markets" (it refuses
///      until the Silicon deployment is recorded there, and if "silicon.usdg" is not USDG), and
///      checks the synth's symbol and 18 decimals and USDG's 6;
///   2. reads the index's USD price from the feed, refusing it unless the feed is fresh for a mint
///      (isFresh: the mint window, every component under 24 hours old, none stopped, not paused),
///      so that the pool opens at a live price; KYZEN_POOL_ALLOW_STALE=1 allows a price outside
///      that, but never one the vault could not liquidate on (isFreshForLiquidation: every
///      component under 96 hours old, none stopped by the breaker);
///   3. plans the pool (synth/USDG, no hook, token order by address) at that price with USDG at
///      $1.00, refusing a pool that already has a price, and the position:
///      - bid: KYZEN_POOL_<SYMBOL>_USDG of USDG from the first usable tick below the index price
///        down to the index price less KYZEN_POOL_RANGE_BPS (widened to the tick spacing), on the
///        side of the pool's tick where the position holds only USDG for either token order; no
///        synth is taken or approved;
///      - two-sided: what the two amounts pay for (the smaller side binds; the other side's
///        remainder stays in the wallet);
///   4. checks the owner's balances cover every planned position, before sending anything;
///   5. sends, from the owner, per pool: the synth's and USDG's approvals to Permit2, Permit2's
///      approvals of the PositionManager (each for the position's maxima, until 30 minutes after
///      the run), and one PositionManager multicall that initialises the pool and mints the
///      position to the owner (lib/SiliconPoolSeed.sol);
///   6. reads each pool back (price, tick, fee, liquidity, the NFT's owner and liquidity).
///
/// Environment (amounts in base units: the synth has 18 decimals, USDG 6):
///   KYZEN_POOL_MODE          required: bid or two-sided
///   KYZEN_POOL_KDESIGN_USDG, KYZEN_POOL_KDESIGN_SYNTH     (and the same for KMEMORY, KFAB, KEQUIP)
///       bid: the USDG only (a synth amount is refused); two-sided: both, a market with one of the
///       two is refused; either way a market with neither is skipped
///   KYZEN_POOL_FEE           required: the LP fee in hundredths of a bip (3000 is 0.30%)
///   KYZEN_POOL_TICK_SPACING  required: the pool's tick spacing
///   KYZEN_POOL_RANGE_BPS     required: bid: how far below the index price the bid reaches (above 0);
///                            two-sided: 0 for the full range, otherwise the index price plus and
///                            minus this many basis points; widened to the tick spacing either way
///   KYZEN_POOL_ALLOW_STALE   optional: 1 allows an index price outside the mint window (step 2)
/// No setting has a default. The owner's decision (SPEC 3.5): bid, 3000, 60 and 1000 (0.30%,
/// Uniswap's spacing for that tier, a bid from the index price down 10%), $100 of USDG per pool.
///
///   cd contracts
///   KYZEN_POOL_MODE=bid KYZEN_POOL_FEE=3000 KYZEN_POOL_TICK_SPACING=60 KYZEN_POOL_RANGE_BPS=1000 \
///   KYZEN_POOL_KDESIGN_USDG=$(cast parse-units 100 6) ... \
///     forge script script/SiliconPools.s.sol --rpc-url robinhood --private-key <owner key>
///   (a simulation; the same with --broadcast --slow sends it once it reads right)
///
/// Re-placing a bid (`--sig "replace(string)" <SYMBOL>`), for an index that moved above its bid:
///   1. checks the owner wallet, the market, the index price (the same freshness rules), and that
///      position KYZEN_POOL_<SYMBOL>_TOKEN_ID belongs to the owner wallet and sits in the market's
///      synth/USDG pool with KYZEN_POOL_FEE and KYZEN_POOL_TICK_SPACING;
///   2. removes all of its liquidity and takes everything it holds, fees included, to the owner
///      wallet (the NFT stays the owner's, empty). Synth the bid bought from sellers comes back too:
///      the owner forwards it to the fee router or keeps it;
///   3. if the pool's price is below the index price, deploys a V4PriceMover (lib/V4PriceMover.sol)
///      and moves the pool's price, now with no liquidity in the way, to the index price for free;
///   4. places a new bid with all the USDG that came back, from the first usable tick below the index
///      price down KYZEN_POOL_RANGE_BPS, minted to the owner wallet as a new position NFT.
///
///   KYZEN_POOL_FEE=3000 KYZEN_POOL_TICK_SPACING=60 KYZEN_POOL_RANGE_BPS=1000 KYZEN_POOL_KDESIGN_TOKEN_ID=<id> \
///     forge script script/SiliconPools.s.sol --sig "replace(string)" kDESIGN --rpc-url robinhood --private-key <owner key>
contract SiliconPools is Script {
    string internal constant DEPLOYMENT = "deployments/4663.json";
    uint256 internal constant MARKETS = 4;
    /// How long the multicall and the Permit2 approvals stay valid after the run reads the chain.
    uint256 internal constant DEADLINE = 30 minutes;
    uint8 internal constant SYNTH_DECIMALS = 18;
    uint8 internal constant USDG_DECIMALS = 6;
    /// One USDG base unit per synth base unit is this USD price (18 decimals): 10^(18 + 18 - 6).
    uint256 internal constant SCALE = 1e30;

    /// What a re-placing run returned and placed.
    struct Replaced {
        /// USDG and synth the old position returned to the owner wallet, its fees included.
        uint256 usdgBack;
        uint256 synthBack;
        /// The V4PriceMover deployed to move the pool's price (zero when none was needed).
        address mover;
        /// The new bid's position NFT (zero when nothing came back to place).
        uint256 newTokenId;
    }

    /// How the run seeds: a USDG-only bid or a two-sided position, and whether index prices outside
    /// the mint window are allowed.
    struct Options {
        bool bid;
        bool allowStale;
    }

    struct Market {
        string symbol;
        address synth;
        address feed;
        /// Base units the owner offers to the pool.
        uint256 synthAmount;
        uint256 usdgAmount;
    }

    error NotMainnet(uint256 chainId);
    /// Only the owner wallet seeds the pools.
    error NotOwnerWallet(address sender, address owner);
    /// A required environment setting is not set.
    error MissingSetting(string name);
    /// The deployment file has no Silicon markets yet: deploy Silicon on mainnet and record it first.
    error NoSiliconMarkets(string file);
    /// The deployment file's Silicon markets do not include this index.
    error MarketNotRecorded(string symbol, string file);
    /// The deployment file's "silicon.usdg" is not USDG.
    error WrongUsdg(address recorded, address expected);
    error NoCode(string what, address account);
    error WrongSymbol(address synth, string expected, string actual);
    error WrongDecimals(address token, uint8 expected, uint8 actual);
    /// The index feed has no price.
    error NoIndexPrice(string symbol);
    /// The index price is not fresh for a mint (outside the mint window, a component over 24
    /// hours old or stopped, or the index paused); KYZEN_POOL_ALLOW_STALE=1 allows it.
    error IndexNotFresh(string symbol, uint256 updatedAt);
    /// The index price is too old for a liquidation (a component over 96 hours) or stopped by the
    /// breaker; nothing allows it.
    error StaleIndexPrice(string symbol, uint256 updatedAt);
    /// A market has one of its two amounts and not the other (two-sided).
    error OneAmountMissing(string symbol);
    /// A bid takes USDG only; the market has a synth amount.
    error SynthAmountInBidMode(string symbol);
    /// No market has amounts in the environment.
    error NothingToSeed();
    error InsufficientBalance(address token, uint256 needed, uint256 balance);
    /// An environment setting does not fit its type.
    error BadSetting(string name);
    /// The symbol is not one of the four indices.
    error UnknownMarket(string symbol);
    /// The position belongs to another address than the owner wallet.
    error NotPositionOwner(uint256 tokenId, address owner, address holder);
    /// The position is not in this market's synth/USDG pool with these settings.
    error WrongPosition(uint256 tokenId);

    function run() external {
        if (block.chainid != RH.CHAIN_ID) revert NotMainnet(block.chainid);
        if (msg.sender != Terms.OWNER) revert NotOwnerWallet(msg.sender, Terms.OWNER);
        Market[MARKETS] memory list = amountsFromEnv(markets(vm.readFile(DEPLOYMENT)));
        Options memory o = Options({bid: bidFromEnv(), allowStale: allowStaleFromEnv()});
        _seedAll(msg.sender, list, settingsFromEnv(), o);
    }

    /// Re-places `symbol`'s bid at the current index price (see the header): the position
    /// KYZEN_POOL_<SYMBOL>_TOKEN_ID, with the pool and range settings from the environment.
    function replace(string calldata symbol) external {
        if (block.chainid != RH.CHAIN_ID) revert NotMainnet(block.chainid);
        if (msg.sender != Terms.OWNER) revert NotOwnerWallet(msg.sender, Terms.OWNER);
        Market memory m = _market(markets(vm.readFile(DEPLOYMENT)), symbol);
        uint256 tokenId = vm.envUint(_required(string.concat("KYZEN_POOL_", vm.toUppercase(m.symbol), "_TOKEN_ID")));
        replaceBid(msg.sender, m, settingsFromEnv(), tokenId, allowStaleFromEnv());
    }

    /// Re-places market `m`'s bid, position `tokenId`, from `owner` (the owner wallet): removes it to
    /// the owner wallet, moves the pool's price up to the index price if it is below, and places a
    /// new bid with the USDG that came back. Returns the new bid's plan and what happened.
    function replaceBid(address owner, Market memory m, Seed.Settings memory s, uint256 tokenId, bool allowStale)
        public
        returns (Seed.Plan memory p, Replaced memory r)
    {
        if (owner != Terms.OWNER) revert NotOwnerWallet(owner, Terms.OWNER);
        if (s.rangeBps == 0) revert BadSetting("KYZEN_POOL_RANGE_BPS");
        Seed.checkSettings(s);
        _checkToken("USDG", RH.USDG, USDG_DECIMALS);
        _checkSynth(m);
        uint256 price = _indexPrice(m, allowStale);
        PoolKey memory key = Seed.keyFor(m.synth, RH.USDG, s);
        _checkPosition(owner, tokenId, key);

        (r.usdgBack, r.synthBack) = _removeAll(owner, m.synth, tokenId, key);
        if (r.usdgBack == 0) {
            console2.log("No USDG came back: no new bid placed for", m.symbol);
            _reportBack(m, tokenId, r);
            return (p, r);
        }
        r.mover = _moveToIndex(owner, key, m.synth < RH.USDG, price);
        p = Seed.planBidAt(m.synth, RH.USDG, price, r.usdgBack, s);
        vm.startBroadcast(owner);
        r.newTokenId = Seed.seed(p, owner, block.timestamp + DEADLINE);
        vm.stopBroadcast();
        Seed.checkPosition(p, r.newTokenId, owner);
        _reportBack(m, tokenId, r);
        _report(m, p, r.newTokenId);
    }

    /// kDESIGN, kMEMORY, kFAB, kEQUIP.
    function symbolAt(uint256 i) public pure returns (string memory) {
        if (i == 0) return "kDESIGN";
        if (i == 1) return "kMEMORY";
        if (i == 2) return "kFAB";
        return "kEQUIP";
    }

    /// The four index markets' synths and feeds from a deployment file's "silicon.markets".
    function markets(string memory json) public view returns (Market[MARKETS] memory list) {
        if (!vm.keyExistsJson(json, ".silicon.markets")) revert NoSiliconMarkets(DEPLOYMENT);
        // The vault's collateral USDG, when recorded, is the USDG the pools pair with.
        if (vm.keyExistsJson(json, ".silicon.usdg")) {
            address recorded = vm.parseJsonAddress(json, ".silicon.usdg");
            if (recorded != RH.USDG) revert WrongUsdg(recorded, RH.USDG);
        }
        uint256 n;
        while (vm.keyExistsJson(json, _entry(n))) ++n;
        for (uint256 i; i < MARKETS; ++i) {
            string memory symbol = symbolAt(i);
            bool found;
            for (uint256 j; j < n && !found; ++j) {
                string memory e = _entry(j);
                if (keccak256(bytes(vm.parseJsonString(json, string.concat(e, ".symbol")))) != keccak256(bytes(symbol)))
                {
                    continue;
                }
                list[i].symbol = symbol;
                list[i].synth = vm.parseJsonAddress(json, string.concat(e, ".synth"));
                list[i].feed = vm.parseJsonAddress(json, string.concat(e, ".feed"));
                found = true;
            }
            if (!found) revert MarketNotRecorded(symbol, DEPLOYMENT);
        }
    }

    /// Each market's amounts from KYZEN_POOL_<SYMBOL>_SYNTH and KYZEN_POOL_<SYMBOL>_USDG (unset: 0).
    function amountsFromEnv(Market[MARKETS] memory list) public view returns (Market[MARKETS] memory) {
        for (uint256 i; i < MARKETS; ++i) {
            string memory prefix = string.concat("KYZEN_POOL_", vm.toUppercase(list[i].symbol));
            list[i].synthAmount = vm.envOr(string.concat(prefix, "_SYNTH"), uint256(0));
            list[i].usdgAmount = vm.envOr(string.concat(prefix, "_USDG"), uint256(0));
        }
        return list;
    }

    /// The fee, tick spacing and range from the environment. Each is required: the owner decides
    /// the tier, and the pool's id follows from it for good.
    function settingsFromEnv() public view returns (Seed.Settings memory s) {
        uint256 fee = vm.envUint(_required("KYZEN_POOL_FEE"));
        int256 spacing = vm.envInt(_required("KYZEN_POOL_TICK_SPACING"));
        uint256 rangeBps = vm.envUint(_required("KYZEN_POOL_RANGE_BPS"));
        if (fee > type(uint24).max) revert BadSetting("KYZEN_POOL_FEE");
        if (spacing < 1 || spacing > type(int24).max) revert BadSetting("KYZEN_POOL_TICK_SPACING");
        s = Seed.Settings({fee: uint24(fee), tickSpacing: int24(spacing), rangeBps: rangeBps});
        Seed.checkSettings(s);
    }

    /// KYZEN_POOL_MODE, required: "bid" (true) or "two-sided" (false).
    function bidFromEnv() public view returns (bool) {
        bytes32 mode = keccak256(bytes(vm.envString(_required("KYZEN_POOL_MODE"))));
        if (mode == keccak256("bid")) return true;
        if (mode == keccak256("two-sided")) return false;
        revert BadSetting("KYZEN_POOL_MODE");
    }

    /// KYZEN_POOL_ALLOW_STALE: unset or 0 refuses an index price outside the mint window, 1 allows it.
    function allowStaleFromEnv() public view returns (bool) {
        uint256 v = vm.envOr("KYZEN_POOL_ALLOW_STALE", uint256(0));
        if (v > 1) revert BadSetting("KYZEN_POOL_ALLOW_STALE");
        return v == 1;
    }

    /// Two-sided: plans every market with amounts, checks the owner's balances, then seeds each
    /// pool from `owner`, which must be the owner wallet, and reads it back. Returns the plans and
    /// the position NFTs' ids, in market order. `allowStale` allows index prices outside the mint
    /// window (KYZEN_POOL_ALLOW_STALE=1).
    function seed(address owner, Market[MARKETS] memory list, Seed.Settings memory s, bool allowStale)
        public
        returns (Seed.Plan[] memory plans, uint256[] memory tokenIds)
    {
        return _seedAll(owner, list, s, Options({bid: false, allowStale: allowStale}));
    }

    /// As seed(), with a USDG-only bid in each market (KYZEN_POOL_MODE=bid).
    function seedBids(address owner, Market[MARKETS] memory list, Seed.Settings memory s, bool allowStale)
        public
        returns (Seed.Plan[] memory plans, uint256[] memory tokenIds)
    {
        return _seedAll(owner, list, s, Options({bid: true, allowStale: allowStale}));
    }

    function _seedAll(address owner, Market[MARKETS] memory list, Seed.Settings memory s, Options memory o)
        private
        returns (Seed.Plan[] memory plans, uint256[] memory tokenIds)
    {
        if (owner != Terms.OWNER) revert NotOwnerWallet(owner, Terms.OWNER);
        Seed.checkSettings(s);
        _checkToken("USDG", RH.USDG, USDG_DECIMALS);
        _logSettings(owner, s, o);
        (Seed.Plan[MARKETS] memory planned, bool[MARKETS] memory active, uint256 count) = _planAll(owner, list, s, o);

        plans = new Seed.Plan[](count);
        tokenIds = new uint256[](count);
        uint256 k;
        for (uint256 i; i < MARKETS; ++i) {
            if (!active[i]) continue;
            vm.startBroadcast(owner);
            uint256 tokenId = Seed.seed(planned[i], owner, block.timestamp + DEADLINE);
            vm.stopBroadcast();
            Seed.check(planned[i], tokenId, owner);
            _report(list[i], planned[i], tokenId);
            plans[k] = planned[i];
            tokenIds[k] = tokenId;
            ++k;
        }
    }

    /// Every market with amounts, planned and checked, and the owner's USDG for all of them,
    /// before anything is sent.
    function _planAll(address owner, Market[MARKETS] memory list, Seed.Settings memory s, Options memory o)
        private
        view
        returns (Seed.Plan[MARKETS] memory planned, bool[MARKETS] memory active, uint256 count)
    {
        uint256 usdgNeeded;
        for (uint256 i; i < MARKETS; ++i) {
            Market memory m = list[i];
            if (m.synthAmount == 0 && m.usdgAmount == 0) {
                console2.log("Skipped (no amounts):", m.symbol);
                continue;
            }
            planned[i] = _plan(m, s, owner, o);
            (, uint256 usdgMax) = Seed.maxima(planned[i]);
            usdgNeeded += usdgMax;
            active[i] = true;
            ++count;
        }
        if (count == 0) revert NothingToSeed();
        uint256 usdgBalance = IERC20(RH.USDG).balanceOf(owner);
        if (usdgBalance < usdgNeeded) revert InsufficientBalance(RH.USDG, usdgNeeded, usdgBalance);
    }

    function _logSettings(address owner, Seed.Settings memory s, Options memory o) private pure {
        console2.log("Owner         ", owner);
        console2.log("Mode          ", o.bid ? "bid (USDG only)" : "two-sided");
        console2.log("LP fee (pips) ", s.fee);
        console2.log("Tick spacing  ", uint256(int256(s.tickSpacing)));
        if (o.bid) console2.log("Bid depth (bps below the index price)", s.rangeBps);
        else console2.log("Range (bps)   ", s.rangeBps, s.rangeBps == 0 ? "(full range)" : "");
        if (o.allowStale) console2.log("KYZEN_POOL_ALLOW_STALE=1: prices outside the mint window allowed");
    }

    /// Market `m`'s pool and position, after checking its synth, its price and the owner's synth.
    function _plan(Market memory m, Seed.Settings memory s, address owner, Options memory o)
        private
        view
        returns (Seed.Plan memory p)
    {
        if (o.bid) {
            if (m.synthAmount != 0) revert SynthAmountInBidMode(m.symbol);
        } else if (m.synthAmount == 0 || m.usdgAmount == 0) {
            revert OneAmountMissing(m.symbol);
        }
        _checkSynth(m);
        uint256 price = _indexPrice(m, o.allowStale);
        if (o.bid) return Seed.planBid(m.synth, RH.USDG, price, m.usdgAmount, s);
        p = Seed.plan(m.synth, RH.USDG, price, m.synthAmount, m.usdgAmount, s);
        (uint256 synthMax,) = Seed.maxima(p);
        uint256 balance = IERC20(m.synth).balanceOf(owner);
        if (balance < synthMax) revert InsufficientBalance(m.synth, synthMax, balance);
    }

    /// The index's USD price (18 decimals): refused unless fresh for a mint (or `allowStale`), and
    /// always refused when the vault could not liquidate on it.
    function _indexPrice(Market memory m, bool allowStale) private view returns (uint256 price) {
        if (m.feed.code.length == 0) revert NoCode(string.concat(m.symbol, " feed"), m.feed);
        ISiliconFeed feed = ISiliconFeed(m.feed);
        uint256 updatedAt;
        (price, updatedAt) = feed.latestPrice();
        if (price == 0) revert NoIndexPrice(m.symbol);
        if (!feed.isFreshForLiquidation()) revert StaleIndexPrice(m.symbol, updatedAt);
        if (!feed.isFresh()) {
            if (!allowStale) revert IndexNotFresh(m.symbol, updatedAt);
            console2.log("Allowed: outside the mint window, the price is the last close:", m.symbol);
        }
    }

    /// The synth has code, the market's symbol and 18 decimals.
    function _checkSynth(Market memory m) private view {
        _checkToken(m.symbol, m.synth, SYNTH_DECIMALS);
        string memory actual = IERC20Metadata(m.synth).symbol();
        if (keccak256(bytes(actual)) != keccak256(bytes(m.symbol))) revert WrongSymbol(m.synth, m.symbol, actual);
    }

    /// Position `tokenId` is the owner wallet's and sits in pool `key`.
    function _checkPosition(address owner, uint256 tokenId, PoolKey memory key) private view {
        IV4PositionManager posm = IV4PositionManager(RH.UNISWAP_V4_POSITION_MANAGER);
        address holder = posm.ownerOf(tokenId);
        if (holder != owner) revert NotPositionOwner(tokenId, owner, holder);
        (PoolKey memory actual,) = posm.getPoolAndPositionInfo(tokenId);
        if (keccak256(abi.encode(actual)) != keccak256(abi.encode(key))) revert WrongPosition(tokenId);
    }

    /// Removes position `tokenId` to the owner wallet; returns the USDG and synth that came back.
    function _removeAll(address owner, address synth, uint256 tokenId, PoolKey memory key)
        private
        returns (uint256 usdgBack, uint256 synthBack)
    {
        uint256 usdgBefore = IERC20(RH.USDG).balanceOf(owner);
        uint256 synthBefore = IERC20(synth).balanceOf(owner);
        vm.startBroadcast(owner);
        Seed.removeAll(tokenId, key, owner, block.timestamp + DEADLINE);
        vm.stopBroadcast();
        usdgBack = IERC20(RH.USDG).balanceOf(owner) - usdgBefore;
        synthBack = IERC20(synth).balanceOf(owner) - synthBefore;
    }

    /// If the pool prices the synth below the index price, deploys a V4PriceMover and moves the
    /// pool's price to the index price (the pool's own liquidity was just removed; anyone else's in
    /// the way makes the move revert). Returns the mover, or zero when no move was needed.
    function _moveToIndex(address owner, PoolKey memory key, bool synthIsCurrency0, uint256 price)
        private
        returns (address mover)
    {
        (uint160 current,,,) = IV4StateView(RH.UNISWAP_V4_STATE_VIEW).getSlot0(keccak256(abi.encode(key)));
        uint160 target = M.sqrtPriceForUsd(price, synthIsCurrency0, SCALE);
        // The synth is cheaper in the pool than the index: a higher pool price when it is currency0,
        // a lower one when it is currency1.
        bool below = synthIsCurrency0 ? current < target : current > target;
        if (!below) return address(0);
        vm.startBroadcast(owner);
        V4PriceMover mv = new V4PriceMover(IV4PoolManager(RH.UNISWAP_V4_POOL_MANAGER));
        mv.moveTo(key, !synthIsCurrency0, target);
        vm.stopBroadcast();
        mover = address(mv);
    }

    function _market(Market[MARKETS] memory list, string memory symbol) private pure returns (Market memory) {
        for (uint256 i; i < MARKETS; ++i) {
            if (keccak256(bytes(list[i].symbol)) == keccak256(bytes(symbol))) return list[i];
        }
        revert UnknownMarket(symbol);
    }

    function _reportBack(Market memory m, uint256 oldTokenId, Replaced memory r) private pure {
        console2.log("");
        console2.log(m.symbol, "old bid removed; its position NFT (now empty)", oldTokenId);
        console2.log("  USDG back to the owner wallet (fees included)", r.usdgBack);
        console2.log("  synth back to the owner wallet (bought from sellers, fees included)", r.synthBack);
        if (r.synthBack != 0) {
            console2.log("  -> that synth is now in the owner wallet: forward it to the fee router or keep it");
        }
        if (r.mover != address(0)) console2.log("  pool price moved to the index price by V4PriceMover", r.mover);
    }

    function _checkToken(string memory name, address token, uint8 decimals) private view {
        if (token.code.length == 0) revert NoCode(name, token);
        uint8 actual = IERC20Metadata(token).decimals();
        if (actual != decimals) revert WrongDecimals(token, decimals, actual);
    }

    function _report(Market memory m, Seed.Plan memory p, uint256 tokenId) private pure {
        (uint256 synthUsed, uint256 usdgUsed) = Seed.amounts(p);
        console2.log("");
        console2.log(m.symbol, "/ USDG pool id");
        console2.logBytes32(p.poolId);
        console2.log("  synth                 ", m.synth);
        console2.log("  synth is currency     ", p.synthIsCurrency0 ? "0" : "1");
        console2.log("  index price (USD, 1e18)", p.usdPrice);
        console2.log("  sqrtPriceX96          ", p.sqrtPriceX96);
        console2.log("  tick                  ", _signed(p.tick));
        console2.log("  range ticks           ", _signed(p.tickLower), _signed(p.tickUpper));
        if (p.tickLower != M.minUsableTick(p.key.tickSpacing) || p.tickUpper != M.maxUsableTick(p.key.tickSpacing)) {
            uint256 a = M.usdForSqrtPrice(M.getSqrtPriceAtTick(p.tickLower), p.synthIsCurrency0, p.scale);
            uint256 b = M.usdForSqrtPrice(M.getSqrtPriceAtTick(p.tickUpper), p.synthIsCurrency0, p.scale);
            console2.log("  range (USD, 1e18)     ", a < b ? a : b, a < b ? b : a);
        }
        console2.log("  liquidity             ", p.liquidity);
        console2.log("  synth in / offered    ", synthUsed, m.synthAmount);
        console2.log("  USDG in / offered     ", usdgUsed, m.usdgAmount);
        console2.log("  position NFT id       ", tokenId);
    }

    function _signed(int24 v) private pure returns (string memory) {
        return v < 0 ? string.concat("-", vm.toString(uint256(-int256(v)))) : vm.toString(uint256(int256(v)));
    }

    function _required(string memory name) private view returns (string memory) {
        if (!vm.envExists(name)) revert MissingSetting(name);
        return name;
    }

    function _entry(uint256 j) private pure returns (string memory) {
        return string.concat(".silicon.markets[", vm.toString(j), "]");
    }
}
