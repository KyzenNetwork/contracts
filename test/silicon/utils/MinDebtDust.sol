// SPDX-License-Identifier: MIT
pragma solidity 0.8.37;

// How far under the minimum debt a position may read when it did not act, in synth wei: the one
// allowance the minimum-debt invariants of both Silicon invariant suites share.
//
// Another account's action moves the debt per share by rounding, in the vault's favour: a mint
// rounds the minter's new shares up, and a part repay retires the payer's shares rounded down.
// Either lowers the debt per share by under a wei once the borrow fee has accrued, so a position
// left at exactly the minimum can later read a wei under it (at most a wei per such action, far
// below any value). The vault checks the minimum only when a position's owner mints or repays in
// part, so the acting account is held to the minimum exactly; any other account owes nothing or
// at least the minimum less DUST.
uint256 constant DUST = 1_000;
