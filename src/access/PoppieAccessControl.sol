// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {MS_OPS, K_PRICE, K_CONFIRM, K_TIGHTEN, K_LOOSEN, K_ALLOC, K_GUARD, K_RESERVE} from "./Roles.sol";

/// @title PoppieAccessControl
/// @notice Shared role base for every Poppie contract that has roles.
/// @dev - The timelock holds `DEFAULT_ADMIN_ROLE`. It is the only account that can grant any role.
///      - `MS_OPS` can revoke the `K_*` roles but cannot grant them (or anything else).
///      - Every other role keeps OpenZeppelin's rule: only the role admin (the timelock) revokes it.
///      Role identifiers live in `Roles.sol`. Derived contracts gate functions with `onlyRole(...)`.
abstract contract PoppieAccessControl is AccessControl {
    error ZeroAddress();

    /// @param timelock Receives `DEFAULT_ADMIN_ROLE`. Must be non-zero.
    constructor(address timelock) {
        if (timelock == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, timelock);
    }

    /// @notice True for the key roles that `MS_OPS` is allowed to revoke.
    function isKeyRole(bytes32 role) public pure returns (bool) {
        return role == K_PRICE || role == K_CONFIRM || role == K_TIGHTEN || role == K_LOOSEN || role == K_ALLOC
            || role == K_GUARD || role == K_RESERVE;
    }

    /// @notice Revokes `role` from `account`.
    /// @dev Callable by the role admin (the timelock), or by `MS_OPS` when `role` is a `K_*` role.
    function revokeRole(bytes32 role, address account) public virtual override {
        if (isKeyRole(role) && hasRole(MS_OPS, _msgSender())) {
            _revokeRole(role, account);
            return;
        }
        super.revokeRole(role, account);
    }
}
