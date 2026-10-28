// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// Role identifiers shared by every Poppie contract (CONTRACT_SPEC.md section 4).
//
// `MS_ADMIN` (Safe 4-of-7) is not a role on any contract: it proposes to the 48h
// timelock, and the timelock holds `DEFAULT_ADMIN_ROLE` (see PoppieAccessControl).
// Every "MS_ADMIN via timelock" function is therefore `onlyRole(DEFAULT_ADMIN_ROLE)`.

/// @dev Safe 3-of-5. Unpause, listing, fees, liquidation pause, emergency LTV cuts, steward override,
/// ramp cancel, cap ceilings, key revocation. Can revoke `K_*` roles but never grant them.
bytes32 constant MS_OPS = keccak256("MS_OPS");

/// @dev KMS. Oracle: push (both formats), pause.
bytes32 constant K_PRICE = keccak256("K_PRICE");
/// @dev KMS on separate infrastructure. Oracle: confirm, confirm batch.
bytes32 constant K_CONFIRM = keccak256("K_CONFIRM");
/// @dev KMS. Steward: lower functions, demote.
bytes32 constant K_TIGHTEN = keccak256("K_TIGHTEN");
/// @dev MS_OPS Safe in phase 1, a KMS key in phase 2. Steward: raise and promote.
bytes32 constant K_LOOSEN = keccak256("K_LOOSEN");
/// @dev KMS. Euler Earn: reallocate. Not checked by any Poppie contract; listed so MS_OPS can revoke it.
bytes32 constant K_ALLOC = keccak256("K_ALLOC");
/// @dev KMS. Hub hook and escrow hook: time-limited pauses.
bytes32 constant K_GUARD = keccak256("K_GUARD");
/// @dev KMS. Reserve Safe (Roles module): repay only. Not checked by any Poppie contract.
bytes32 constant K_RESERVE = keccak256("K_RESERVE");
