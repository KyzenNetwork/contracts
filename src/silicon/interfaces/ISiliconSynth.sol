// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

/// What SiliconVault calls on a market's synth: only the vault mints and burns.
interface ISiliconSynth {
    /// The vault allowed to mint and burn.
    function vault() external view returns (address);
    /// Mints `amount` to `to`. Vault only.
    function mint(address to, uint256 amount) external;
    /// Burns `amount` from `from`. Vault only; the vault burns only from its caller.
    function burn(address from, uint256 amount) external;
}
