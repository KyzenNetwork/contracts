// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {Ownable, Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {IProtocolPointers} from "./interfaces/IProtocolPointers.sol";
import {IUniswapV2Factory, IUniswapV2Pair, IUniswapV2Router02} from "./interfaces/IUniswapV2.sol";

/// @title Kyzen Network ($KYZN)
/// @notice ERC-20 with 1,000,000,000 $KYZN minted once at deployment and no mint function, and a
/// tax on trades with its Uniswap v2 $KYZN/WETH pool that funds the Kyzen Network Reserve, its
/// stakers and its development. Any holder can burn its own $KYZN, so the supply only falls.
/// @dev
/// - Tax: 5% on buys and 10% on sells at launch, in $KYZN. The owner can only lower each, never below
///   4%. Wallet-to-wallet transfers, trades with any other venue, and the protocol contracts
///   (Reserve, Staking, Gateway) are not taxed. Trades are taxed once the pool holds liquidity, so
///   the launch's first liquidity goes in untaxed.
/// - Split: of every taxed trade, 2% of the trade goes to the Reserve and 1% to Staking; development
///   receives the rest of the tax (2 : 1 : 2 on a 5% buy, 2 : 1 : 7 on a 10% sell, 2 : 1 : 1 at 4%).
/// - Settlement: the tax collects in this contract. On a sell, once it reaches the swap threshold, the
///   contract sells it for ETH through Router02, at most 0.25% of the pool's $KYZN at a time, and pays
///   the Reserve and Staking their shares. Development's share is held here and sent to the
///   development wallet in a transaction of its own (`sendHeldEth`, which anyone may call), so no sell
///   depends on that wallet.
/// - Limit: until the owner removes it, no buy may leave a wallet holding more than 2% of supply.
/// - Owner: until it renounces, the owner can lower the taxes, set the swap threshold, change the
///   development wallet and the Reserve, Staking and Gateway addresses, and remove the max wallet.
///   There is no mint, pause, blacklist or trading switch: trading is open from deployment. After the
///   owner renounces, nothing in the token can change.
/// @custom:security-contact info@kyzen.network
contract KyznToken is ERC20Burnable, Ownable2Step {
    // ------------------------------------------------------------------ constants

    /// @notice The supply minted at deployment, and the most there will ever be.
    uint256 public constant INITIAL_SUPPLY = 1_000_000_000e18;
    /// @notice Basis points in 100%.
    uint256 public constant BPS = 10_000;

    /// @notice The buy tax at launch: 5%.
    uint256 public constant INITIAL_BUY_TAX_BPS = 500;
    /// @notice The sell tax at launch: 10%.
    uint256 public constant INITIAL_SELL_TAX_BPS = 1_000;
    /// @notice The lowest either tax can go: 4%.
    uint256 public constant MIN_TAX_BPS = 400;

    /// @notice Of each taxed trade, the Reserve's share: 2% of the trade, at every tax level.
    uint256 public constant RESERVE_BPS = 200;
    /// @notice Of each taxed trade, Staking's share: 1% of the trade, at every tax level.
    uint256 public constant STAKING_BPS = 100;

    /// @notice The swap threshold at launch: 0.05% of supply.
    uint256 public constant INITIAL_SWAP_THRESHOLD = 500_000e18;
    /// @notice The lowest swap threshold the owner can set: 0.01% of supply.
    uint256 public constant MIN_SWAP_THRESHOLD = 100_000e18;
    /// @notice The highest swap threshold the owner can set: 0.1% of supply.
    uint256 public constant MAX_SWAP_THRESHOLD = 1_000_000e18;
    /// @notice A tax sale sells at most 0.25% of the pool's $KYZN (moving its price by about 0.5%),
    /// and never more than the sell that triggers it.
    uint256 public constant SWAP_POOL_BPS = 25;

    /// @notice The max wallet: 2% of supply.
    uint256 public constant MAX_WALLET = 20_000_000e18;
    /// @notice Gas forwarded with each share sent during a sale, so no recipient can block a trade.
    uint256 public constant SEND_GAS = 50_000;

    // ------------------------------------------------------------------ state

    /// @notice The Uniswap v2 Router02 the tax is sold through.
    IUniswapV2Router02 public immutable router;
    /// @notice WETH, the pool's other side.
    address public immutable weth;
    /// @notice The Uniswap v2 $KYZN/WETH pool: the only venue whose trades are taxed.
    address public immutable pair;
    /// @notice The deployment time: trading is open from then.
    uint256 public immutable launchedAt;

    /// @notice The tax on buys from the pool, in basis points.
    uint256 public buyTaxBps = INITIAL_BUY_TAX_BPS;
    /// @notice The tax on sells to the pool, in basis points.
    uint256 public sellTaxBps = INITIAL_SELL_TAX_BPS;
    /// @notice The tax this contract holds before a sell triggers a tax sale.
    uint256 public swapThreshold = INITIAL_SWAP_THRESHOLD;
    /// @notice Whether the 2% max wallet on buys is on.
    bool public maxWalletActive = true;

    /// @notice The wallet development's share of the tax ETH is held for.
    address public devWallet;
    /// @notice The Reserve: tax-exempt, and the recipient of the Reserve's share.
    address public reserve;
    /// @notice Staking: tax-exempt, and the recipient of the stakers' share.
    address public staking;
    /// @notice The Gateway settlement contract: tax-exempt.
    address public gateway;

    /// @notice Of the tax this contract holds, the $KYZN owed to the Reserve, recorded at each trade's
    /// own tax level.
    uint128 public reserveTaxTokens;
    /// @notice Of the tax this contract holds, the $KYZN owed to Staking, recorded the same way.
    uint128 public stakingTaxTokens;

    /// @notice ETH held for a recipient: development's share of each sale, and any share whose send
    /// failed. `sendHeldEth` sends it.
    mapping(address => uint256) public heldEth;
    /// @notice All ETH held, for every recipient.
    uint256 public totalHeldEth;

    bool private _swapping;

    // ------------------------------------------------------------------ events

    /// @notice The owner lowered one or both taxes.
    event TaxLowered(uint256 previousBuyBps, uint256 previousSellBps, uint256 newBuyBps, uint256 newSellBps);
    /// @notice The owner set the swap threshold.
    event SwapThresholdSet(uint256 amount);
    /// @notice The development wallet was set.
    event DevWalletSet(address indexed wallet);
    /// @notice The owner set the protocol contracts.
    event ProtocolAddressesSet(address indexed reserve, address indexed staking, address indexed gateway);
    /// @notice The max wallet was removed, for good.
    event MaxWalletRemoved();
    /// @notice A tax sale sold `tokensSold` $KYZN for `ethReceived` ETH.
    event TaxSwapped(uint256 tokensSold, uint256 ethReceived);
    /// @notice A tax sale failed; the tax stays held for the next sell to retry.
    event TaxSwapFailed(uint256 tokensOffered);
    /// @notice How a tax sale's ETH was split.
    event TaxDistributed(uint256 toReserve, uint256 toStaking, uint256 toDevelopment);
    /// @notice ETH was held for `recipient`.
    event EthHeld(address indexed recipient, uint256 amount);
    /// @notice ETH held for `recipient` was sent to it.
    event HeldEthSent(address indexed recipient, uint256 amount);

    // ------------------------------------------------------------------ errors

    /// @notice An address argument is zero.
    error ZeroAddress();
    /// @notice The development wallet cannot be the pair, this token, WETH, the router or a protocol contract.
    error BadDevWallet();
    /// @notice A protocol address is a duplicate, a core address, or does not read back as built for this token.
    error BadProtocolAddress();
    /// @notice A tax may not rise, and a call must lower at least one.
    error TaxNotLower();
    /// @notice Neither tax may go below 4%.
    error TaxBelowFloor();
    /// @notice The swap threshold must stay between 0.01% and 0.1% of supply.
    error ThresholdOutOfRange();
    /// @notice A buy would leave the wallet above 2% of supply while the max wallet is on.
    error MaxWalletExceeded();
    /// @notice The max wallet is already removed.
    error MaxWalletAlreadyRemoved();
    /// @notice $KYZN cannot be sent to this contract.
    error TransferToToken();
    /// @notice Only the router sends ETH here, during a tax sale.
    error OnlyRouter();
    /// @notice No ETH is held for that recipient.
    error NothingHeld();
    /// @notice The recipient did not accept the ETH sent to it.
    error EthSendFailed();

    // ------------------------------------------------------------------ constructor

    /// @notice Mints the whole supply to the deployer and creates the $KYZN/WETH pair, or reuses it if
    /// someone created it in advance at this token's address.
    /// @param router_ The Uniswap v2 Router02.
    /// @param devWallet_ The development wallet.
    constructor(IUniswapV2Router02 router_, address devWallet_) ERC20("Kyzen Network", "KYZN") Ownable(msg.sender) {
        if (address(router_) == address(0) || devWallet_ == address(0)) revert ZeroAddress();
        address weth_ = router_.WETH();
        IUniswapV2Factory factory = IUniswapV2Factory(router_.factory());
        address pair_ = factory.getPair(address(this), weth_);
        if (pair_ == address(0)) pair_ = factory.createPair(address(this), weth_);

        router = router_;
        weth = weth_;
        pair = pair_;
        launchedAt = block.timestamp;
        if (_isCoreAddress(devWallet_)) revert BadDevWallet();
        devWallet = devWallet_;
        emit DevWalletSet(devWallet_);
        _mint(msg.sender, INITIAL_SUPPLY);
    }

    /// @notice ETH arrives only from the router, during a tax sale.
    receive() external payable {
        if (msg.sender != address(router) || !_swapping) revert OnlyRouter();
    }

    // ------------------------------------------------------------------ owner

    /// @notice Lowers the buy tax, the sell tax or both. Neither may rise, at least one must fall, and
    /// neither may go below 4%.
    /// @param newBuyBps The new buy tax, in basis points.
    /// @param newSellBps The new sell tax, in basis points.
    function lowerTax(uint256 newBuyBps, uint256 newSellBps) external onlyOwner {
        uint256 buyBps = buyTaxBps;
        uint256 sellBps = sellTaxBps;
        if (newBuyBps > buyBps || newSellBps > sellBps || (newBuyBps == buyBps && newSellBps == sellBps)) {
            revert TaxNotLower();
        }
        if (newBuyBps < MIN_TAX_BPS || newSellBps < MIN_TAX_BPS) revert TaxBelowFloor();
        buyTaxBps = newBuyBps;
        sellTaxBps = newSellBps;
        emit TaxLowered(buyBps, sellBps, newBuyBps, newSellBps);
    }

    /// @notice Sets how much tax this contract holds before a sell triggers a tax sale.
    /// @param amount Between 100,000 and 1,000,000 $KYZN (18 decimals).
    function setSwapThreshold(uint256 amount) external onlyOwner {
        if (amount < MIN_SWAP_THRESHOLD || amount > MAX_SWAP_THRESHOLD) revert ThresholdOutOfRange();
        swapThreshold = amount;
        emit SwapThresholdSet(amount);
    }

    /// @notice Sets the wallet development's ETH is held for. ETH already held for the previous wallet
    /// stays held for it, and `sendHeldEth(previous)` sends it there.
    /// @param wallet Never the pair, this token, WETH, the router or a protocol contract.
    function setDevWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        if (_isCoreAddress(wallet) || isExempt(wallet)) revert BadDevWallet();
        devWallet = wallet;
        emit DevWalletSet(wallet);
    }

    /// @notice Sets the Reserve, Staking and the Gateway: tax-exempt, and the recipients of the
    /// Reserve's and Staking's tax shares from the next sale on.
    /// @dev The three must be distinct and none of them the pair, this token, WETH, the router or the
    /// development wallet. Each must read back this token's addresses: the Reserve this token and WETH;
    /// Staking this token, that Reserve and the router; the Gateway this token and the router. The read
    /// back guards against a wrong address; it does not prove a contract's code.
    /// @param reserve_ The Reserve.
    /// @param staking_ Staking.
    /// @param gateway_ The Gateway settlement contract.
    function setProtocolAddresses(address reserve_, address staking_, address gateway_) external onlyOwner {
        if (reserve_ == address(0) || staking_ == address(0) || gateway_ == address(0)) revert ZeroAddress();
        if (
            _isCoreAddress(reserve_) || _isCoreAddress(staking_) || _isCoreAddress(gateway_) || reserve_ == staking_
                || reserve_ == gateway_ || staking_ == gateway_ || devWallet == reserve_ || devWallet == staking_
                || devWallet == gateway_
        ) revert BadProtocolAddress();
        address router_ = address(router);
        if (
            !_reads(reserve_, IProtocolPointers.kyzn.selector, address(this))
                || !_reads(reserve_, IProtocolPointers.weth.selector, weth)
                || !_reads(staking_, IProtocolPointers.kyzn.selector, address(this))
                || !_reads(staking_, IProtocolPointers.reserve.selector, reserve_)
                || !_reads(staking_, IProtocolPointers.router.selector, router_)
                || !_reads(gateway_, IProtocolPointers.kyzn.selector, address(this))
                || !_reads(gateway_, IProtocolPointers.router.selector, router_)
        ) revert BadProtocolAddress();
        reserve = reserve_;
        staking = staking_;
        gateway = gateway_;
        emit ProtocolAddressesSet(reserve_, staking_, gateway_);
    }

    /// @notice Removes the 2% max wallet, for good.
    function removeMaxWallet() external onlyOwner {
        if (!maxWalletActive) revert MaxWalletAlreadyRemoved();
        _removeMaxWallet();
    }

    /// @notice Gives up ownership for good. Also removes the max wallet, if still on, since no owner
    /// would be left to remove it.
    function renounceOwnership() public override onlyOwner {
        if (maxWalletActive) _removeMaxWallet();
        super.renounceOwnership();
    }

    // ------------------------------------------------------------------ held ETH

    /// @notice Sends `recipient` the ETH held for it. Anyone may call it; the protocol's server does,
    /// for the development wallet, shortly after each sale.
    /// @param recipient The address the ETH is held for, and goes to.
    function sendHeldEth(address recipient) external {
        uint256 amount = heldEth[recipient];
        if (amount == 0) revert NothingHeld();
        heldEth[recipient] = 0;
        totalHeldEth -= amount;
        emit HeldEthSent(recipient, amount);
        (bool ok,) = payable(recipient).call{value: amount}("");
        if (!ok) revert EthSendFailed();
    }

    // ------------------------------------------------------------------ views

    /// @notice Whether `account` is never taxed and never limited: this token and its protocol
    /// contracts (Reserve, Staking, Gateway).
    /// @param account The address to check.
    function isExempt(address account) public view returns (bool) {
        return account != address(0)
            && (account == address(this) || account == reserve || account == staking || account == gateway);
    }

    // ------------------------------------------------------------------ transfers

    function _update(address from, address to, uint256 value) internal override {
        // Mint (the constructor only) and burn.
        if (from == address(0) || to == address(0)) {
            super._update(from, to, value);
            return;
        }
        // $KYZN sent here would later be sold untaxed and outside the split. (The tax itself
        // arrives through super._update in _collectTax, not through this function.)
        if (to == address(this)) revert TransferToToken();

        bool sell = to == pair;
        uint256 tax;
        if ((sell || from == pair) && !isExempt(from) && !isExempt(to) && _poolHasLiquidity()) {
            if (sell) _sellTaxIfDue(value);
            tax = _collectTax(from, value, sell ? sellTaxBps : buyTaxBps);
        }
        super._update(from, to, value - tax);

        if (maxWalletActive && from == pair && !isExempt(to) && balanceOf(to) > MAX_WALLET) {
            revert MaxWalletExceeded();
        }
    }

    /// Takes the tax into this contract and records the Reserve's and Staking's points of it.
    function _collectTax(address from, uint256 value, uint256 level) private returns (uint256 tax) {
        tax = value * level / BPS;
        if (tax == 0) return 0;
        super._update(from, address(this), tax);
        // Both fit: the whole supply is 1e27, a uint128 holds 3.4e38.
        // forge-lint: disable-next-line(unsafe-typecast)
        reserveTaxTokens += uint128(tax * RESERVE_BPS / level);
        // forge-lint: disable-next-line(unsafe-typecast)
        stakingTaxTokens += uint128(tax * STAKING_BPS / level);
    }

    // ------------------------------------------------------------------ tax settlement

    /// Before a sell reaches the pool: if the tax held is at the threshold, sells some of it, at most
    /// the sell's own size and 0.25% of the pool's $KYZN.
    function _sellTaxIfDue(uint256 sellValue) private {
        // _swapping is defensive: the sale's own transfer is from this exempt contract. With no
        // protocol addresses yet there is no one to pay: the tax waits, recorded.
        if (_swapping || sellValue == 0 || reserve == address(0)) return;
        uint256 pending = balanceOf(address(this));
        if (pending < swapThreshold) return;
        uint256 amount = _min(_min(pending, sellValue), balanceOf(pair) * SWAP_POOL_BPS / BPS);
        if (amount != 0) _swapTax(amount, pending);
    }

    /// Sells `amount` of the `pending` tax for ETH with no minimum out (the bounds above limit its
    /// price impact). A failed sale never blocks the sell that triggered it: the next sell retries.
    function _swapTax(uint256 amount, uint256 pending) private {
        _swapping = true;
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = weth;
        _approve(address(this), address(router), amount);
        uint256 before = address(this).balance;
        try router.swapExactTokensForETHSupportingFeeOnTransferTokens(amount, 0, path, address(this), block.timestamp) {
            uint256 received = address(this).balance - before;
            emit TaxSwapped(amount, received);
            _distribute(received, amount, pending);
        } catch {
            _approve(address(this), address(router), 0);
            emit TaxSwapFailed(amount);
        }
        _swapping = false;
    }

    /// Splits the ETH of a sale of `sold` out of `pending`: the Reserve and Staking get the ETH of
    /// their recorded shares in proportion; development's share is held for its wallet.
    function _distribute(uint256 received, uint256 sold, uint256 pending) private {
        uint256 reserveTokens = reserveTaxTokens;
        uint256 stakingTokens = stakingTaxTokens;
        uint256 reserveSold = reserveTokens * sold / pending;
        uint256 stakingSold = stakingTokens * sold / pending;
        // Both fit: each is at most the recorded amount it is taken from.
        // forge-lint: disable-next-line(unsafe-typecast)
        reserveTaxTokens = uint128(reserveTokens - reserveSold);
        // forge-lint: disable-next-line(unsafe-typecast)
        stakingTaxTokens = uint128(stakingTokens - stakingSold);

        // The recorded shares are at most 3/4 of the tax (3 points of a level of at least 4), so
        // these stay within `received`; the bounds keep a sell from ever reverting here regardless.
        uint256 toReserve = _min(received * reserveSold / sold, received);
        uint256 toStaking = _min(received * stakingSold / sold, received - toReserve);
        uint256 toDevelopment = received - toReserve - toStaking;
        _send(reserve, toReserve);
        _send(staking, toStaking);
        _hold(devWallet, toDevelopment);
        emit TaxDistributed(toReserve, toStaking, toDevelopment);
    }

    /// Sends with a fixed gas allowance and no return data; a failed send is held for `to`.
    function _send(address to, uint256 amount) private {
        if (amount == 0) return;
        uint256 gasLimit = SEND_GAS;
        bool ok;
        assembly ("memory-safe") {
            ok := call(gasLimit, to, amount, 0, 0, 0, 0)
        }
        if (!ok) _hold(to, amount);
    }

    /// Holds `amount` for `to`, for sendHeldEth.
    function _hold(address to, uint256 amount) private {
        if (amount == 0) return;
        heldEth[to] += amount;
        totalHeldEth += amount;
        emit EthHeld(to, amount);
    }

    // ------------------------------------------------------------------ helpers

    /// Trades with the pool are taxed once it holds liquidity: the launch's first liquidity goes in
    /// untaxed. (Uniswap keeps a minimum of liquidity in the pool for good, so it never empties.)
    function _poolHasLiquidity() private view returns (bool) {
        (uint112 reserve0, uint112 reserve1,) = IUniswapV2Pair(pair).getReserves();
        return reserve0 != 0 && reserve1 != 0;
    }

    function _removeMaxWallet() private {
        maxWalletActive = false;
        emit MaxWalletRemoved();
    }

    /// The pair, this token, WETH and the router: never a development wallet or protocol contract.
    function _isCoreAddress(address account) private view returns (bool) {
        return account == pair || account == address(this) || account == weth || account == address(router);
    }

    /// True when `target` answers the no-argument getter `selector` with exactly `expected`.
    function _reads(address target, bytes4 selector, address expected) private view returns (bool) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSelector(selector));
        return ok && data.length == 32 && abi.decode(data, (uint256)) == uint256(uint160(expected));
    }

    function _min(uint256 a, uint256 b) private pure returns (uint256) {
        return a < b ? a : b;
    }
}
