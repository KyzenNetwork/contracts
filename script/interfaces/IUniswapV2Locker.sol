// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// UNCX's country list, as `IUniswapV2Locker.COUNTRY_LIST` returns it.
interface ICountryList {
    function countryIsValid(uint16 countryCode) external view returns (bool);
}

/// UNCX (UniCrypt) Liquidity Locker V2 (SPEC 3.1: LP tokens locked for 6 months), the subset
/// the launch script uses. Verified against uncx-network/liquidity-locker-univ2-contracts,
/// `UniswapV2Locker.sol` (main branch): `lockLPToken`'s fee logic (the
/// ETH fee is exactly `msg.value == gFees.ethFee` when `feeInEth`; `gFees.liquidityFee` per
/// mille of the locked LP amount is always paid to the fee address; the LP token must be a real
/// pair on `uniswapFactory`) and the read-back views used to assert a lock.
///
/// `gFees` is a public struct variable in the real contract (`FeeStruct public gFees;`), and
/// Solidity's auto-generated getter for a public struct returns its members as a flat tuple, not
/// the struct itself (there is no array or mapping member to exclude) — so `gFees()` below
/// returns the tuple, matching the real ABI exactly, not a struct.
interface IUniswapV2Locker {
    struct TokenLock {
        address lpToken;
        uint256 lockDate;
        uint256 amount;
        uint256 initialAmount;
        uint256 unlockDate;
        uint256 lockId;
        address owner;
        uint16 countryCode;
    }

    /// @param referral The referrer address, or address(0) for none.
    /// @param feeInEth True to pay the flatrate fee in ETH (as `msg.value`); false to pay in the
    /// secondary fee token. The launch script always passes true (SPEC 3.1 decides nothing about
    /// holding UNCX/UNCL, so ETH is the only fee asset Kyzen Network needs to source).
    /// @param withdrawer The address that can withdraw the LP tokens once `unlockDate` passes.
    function lockLPToken(
        address lpToken,
        uint256 amount,
        uint256 unlockDate,
        address payable referral,
        bool feeInEth,
        address payable withdrawer,
        uint16 countryCode
    ) external payable;

    function gFees()
        external
        view
        returns (
            uint256 ethFee,
            address secondaryFeeToken,
            uint256 secondaryTokenFee,
            uint256 secondaryTokenDiscount,
            uint256 liquidityFee,
            uint256 referralPercent,
            address referralToken,
            uint256 referralHold,
            uint256 referralDiscount
        );

    function uniswapFactory() external view returns (address);

    /// The country list `lockLPToken` checks `countryCode` against (it reverts "COUNTRY" otherwise).
    /// UNCX numbers countries by its own index, as its app lists them, not by ISO 3166 code.
    function COUNTRY_LIST() external view returns (address);

    function getUserNumLocksForToken(address user, address lpToken) external view returns (uint256);

    function getUserLockForTokenAtIndex(address user, address lpToken, uint256 index)
        external
        view
        returns (TokenLock memory);
}
