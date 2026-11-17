// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev EVK vault subset read by the hooks.
interface IEVaultHook {
    function hookConfig() external view returns (address hookTarget, uint32 hookedOps);
    function totalBorrows() external view returns (uint256);
    function debtOf(address account) external view returns (uint256);
}

/// @dev EVK `Constants.sol` operation bits. Copied, not imported: unverified until phase E (A30 e).
library EVKOps {
    uint32 internal constant OP_DEPOSIT = 1 << 0;
    uint32 internal constant OP_MINT = 1 << 1;
    uint32 internal constant OP_WITHDRAW = 1 << 2;
    uint32 internal constant OP_REDEEM = 1 << 3;
    uint32 internal constant OP_TRANSFER = 1 << 4;
    uint32 internal constant OP_SKIM = 1 << 5;
    uint32 internal constant OP_BORROW = 1 << 6;
    uint32 internal constant OP_REPAY = 1 << 7;
    uint32 internal constant OP_REPAY_WITH_SHARES = 1 << 8;
    uint32 internal constant OP_PULL_DEBT = 1 << 9;
    uint32 internal constant OP_CONVERT_FEES = 1 << 10;
    uint32 internal constant OP_LIQUIDATE = 1 << 11;
    uint32 internal constant OP_FLASHLOAN = 1 << 12;
    uint32 internal constant OP_TOUCH = 1 << 13;
    uint32 internal constant OP_VAULT_STATUS_CHECK = 1 << 14;
}
