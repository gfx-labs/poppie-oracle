// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {
    OP_DEPOSIT,
    OP_MINT,
    OP_TRANSFER,
    OP_SKIM,
    OP_BORROW,
    OP_LIQUIDATE,
    OP_FLASHLOAN,
    OP_VAULT_STATUS_CHECK
} from "evk/EVault/shared/Constants.sol";

// Hooked-operation bitmasks. They are the second argument of EVK's
// `setHookConfig(address hookTarget, uint32 hookedOps)` and the second return value of
// `hookConfig()`. CONTRACT_SPEC.md sections 3.4 and 3.5; the escrow mask is also what
// PoppieRouterGovernor.addResolvedVault checks.
//
// EVK calls the hook target with the original calldata plus the authenticated caller
// (20 bytes) appended, before the operation. OP_VAULT_STATUS_CHECK runs at the end of every
// operation, or at the end of the EVC batch, with the EVC as the appended caller.

/// @dev Hub (USDC borrow vault) hook: borrow, liquidate, flash loan and the vault status check.
/// Never hooked: repay, repay-with-shares, pullDebt, withdraw, redeem, deposit, mint.
uint32 constant HUB_HOOKED_OPS = OP_BORROW | OP_LIQUIDATE | OP_FLASHLOAN | OP_VAULT_STATUS_CHECK;

/// @dev Escrow vault hook: every route by which a token can enter a position.
/// Never hooked: withdraw, redeem (exits are never blocked).
uint32 constant ESCROW_HOOKED_OPS = OP_DEPOSIT | OP_MINT | OP_SKIM | OP_TRANSFER;
