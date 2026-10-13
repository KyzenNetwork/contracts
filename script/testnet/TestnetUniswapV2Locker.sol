// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICountryList, IUniswapV2Locker} from "../interfaces/IUniswapV2Locker.sol";

/// UNCX's country list as deployed beside the Robinhood Chain V2 locker: indexes 0 to 252 valid.
contract TestnetCountryList is ICountryList {
    uint16 public constant COUNTRY_COUNT = 253;

    function countryIsValid(uint16 countryCode) external pure returns (bool) {
        return countryCode < COUNTRY_COUNT;
    }
}

interface IPairTokens {
    function token0() external view returns (address);
    function token1() external view returns (address);
}

interface IFactoryGetPair {
    function getPair(address tokenA, address tokenB) external view returns (address);
}

/// @title Testnet stand-in for UNCX's Liquidity Locker V2 (SPEC 3.1: LP locked for 6 months)
/// @notice Robinhood Chain testnet (46630) has no UNCX deployment, so the testnet launch locks its
/// LP here instead; the offline launch tests use it too. It reproduces the parts of UNCX's
/// `lockLPToken` the launch depends on (UniswapV2Locker.sol, uncx-network/liquidity-locker-univ2-
/// contracts): the country must be in the list, the ETH fee must be exactly `msg.value ==
/// gFees.ethFee` when `feeInEth`, `gFees.liquidityFee` per mille of the locked LP always goes to
/// the fee address, and the LP token must be the real pair for its own tokens on
/// `uniswapFactory`. Referrals and the secondary-token fee are out of scope: the launch uses
/// neither. Locks never release here. Never deployed on mainnet (4663), where the launch uses
/// UNCX's locker (RobinhoodChain.UNCX_V2_LOCKER).
contract TestnetUniswapV2Locker is IUniswapV2Locker {
    address private immutable _factory;
    address payable public feeAddress;
    uint256 public ethFee;
    /// Per mille (parts per 1,000), matching UNCX's `gFees.liquidityFee`.
    uint256 public liquidityFeePerMille;

    address public immutable countryList = address(new TestnetCountryList());
    mapping(uint256 => TokenLock) private _locks;
    mapping(address => mapping(address => uint256[])) private _userLocks;
    uint256 public nextLockId;

    error TimestampInvalid();
    error InsufficientAmount();
    error NotUniV2();
    error FeeNotMet();
    error UnexpectedValue();

    constructor(address factory_, address payable feeAddress_, uint256 ethFee_, uint256 liquidityFeePerMille_) {
        _factory = factory_;
        feeAddress = feeAddress_;
        ethFee = ethFee_;
        liquidityFeePerMille = liquidityFeePerMille_;
    }

    function lockLPToken(
        address lpToken,
        uint256 amount,
        uint256 unlockDate,
        address payable, /* referral: unused, the launch never sets one */
        bool feeInEth,
        address payable withdrawer,
        uint16 countryCode
    ) external payable override {
        require(ICountryList(countryList).countryIsValid(countryCode), "COUNTRY");
        if (unlockDate >= 10_000_000_000) revert TimestampInvalid();
        if (amount == 0) revert InsufficientAmount();
        address token0 = IPairTokens(lpToken).token0();
        address token1 = IPairTokens(lpToken).token1();
        if (IFactoryGetPair(_factory).getPair(token0, token1) != lpToken) revert NotUniV2();

        // A Uniswap v2 pair's LP token reverts on a failed transfer (UNCX's TransferHelper relies on it too).
        // forge-lint: disable-next-line(erc20-unchecked-transfer)
        IERC20(lpToken).transferFrom(msg.sender, address(this), amount);

        if (feeInEth) {
            if (msg.value != ethFee) revert FeeNotMet();
            if (msg.value != 0) {
                (bool ok,) = feeAddress.call{value: msg.value}("");
                require(ok, "TestnetLocker: fee send");
            }
        } else if (msg.value != 0) {
            revert UnexpectedValue();
        }

        uint256 liquidityFee = amount * liquidityFeePerMille / 1000;
        if (liquidityFee != 0) {
            // forge-lint: disable-next-line(erc20-unchecked-transfer)
            IERC20(lpToken).transfer(feeAddress, liquidityFee);
        }
        uint256 amountLocked = amount - liquidityFee;

        uint256 lockId = nextLockId++;
        _locks[lockId] = TokenLock({
            lpToken: lpToken,
            lockDate: block.timestamp,
            amount: amountLocked,
            initialAmount: amountLocked,
            unlockDate: unlockDate,
            lockId: lockId,
            owner: withdrawer,
            countryCode: countryCode
        });
        _userLocks[withdrawer][lpToken].push(lockId);
    }

    function gFees()
        external
        view
        override
        returns (
            uint256 ethFee_,
            address secondaryFeeToken,
            uint256 secondaryTokenFee,
            uint256 secondaryTokenDiscount,
            uint256 liquidityFee_,
            uint256 referralPercent,
            address referralToken,
            uint256 referralHold,
            uint256 referralDiscount
        )
    {
        return (ethFee, address(0), 0, 0, liquidityFeePerMille, 0, address(0), 0, 0);
    }

    function uniswapFactory() external view override returns (address) {
        return _factory;
    }

    function COUNTRY_LIST() external view override returns (address) {
        return countryList;
    }

    function getUserNumLocksForToken(address user, address lpToken) external view override returns (uint256) {
        return _userLocks[user][lpToken].length;
    }

    function getUserLockForTokenAtIndex(address user, address lpToken, uint256 index)
        external
        view
        override
        returns (TokenLock memory)
    {
        return _locks[_userLocks[user][lpToken][index]];
    }
}
