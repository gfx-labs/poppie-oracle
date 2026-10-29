// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ZeroAddress} from "./Errors.sol";
import {MS_OPS, K_PRICE, K_CONFIRM, K_TIGHTEN, K_LOOSEN, K_ALLOC, K_GUARD, K_RESERVE} from "./Roles.sol";

/// @title PoppieAccessControl
/// @notice Shared role base for every Poppie contract that has roles.
/// @dev - `DEFAULT_ADMIN_ROLE` is the only role that can grant any role. In steady state the timelock is its
///        only holder.
///      - Bootstrapping: the constructor grants `DEFAULT_ADMIN_ROLE` to `initialAdmin`. The deploy script
///        passes the deployer key, grants every role and does the one-off setup (e.g. hub registration), then
///        grants `DEFAULT_ADMIN_ROLE` to the timelock and renounces its own roles, so launch never waits on
///        the 48h delay. The configuration check asserts the deployer holds no role afterwards. Passing the
///        timelock directly is also valid.
///      - `MS_OPS` can revoke the `K_*` roles but cannot grant them (or anything else).
///      - Every other role keeps OpenZeppelin's rule: only the role admin (`DEFAULT_ADMIN_ROLE`) revokes it.
///      Role identifiers live in `Roles.sol`. Derived contracts gate functions with `onlyRole(...)`.
abstract contract PoppieAccessControl is AccessControl {
    /// @param initialAdmin Receives `DEFAULT_ADMIN_ROLE`: the deployer key (handed to the timelock at the end
    /// of the deploy script) or the timelock itself. Must be non-zero.
    constructor(address initialAdmin) {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    /// @notice True for the key roles that `MS_OPS` is allowed to revoke.
    function isKeyRole(bytes32 role) public pure returns (bool) {
        return role == K_PRICE || role == K_CONFIRM || role == K_TIGHTEN || role == K_LOOSEN || role == K_ALLOC
            || role == K_GUARD || role == K_RESERVE;
    }

    /// @notice Revokes `role` from `account`.
    /// @dev Callable by the role admin (`DEFAULT_ADMIN_ROLE`), or by `MS_OPS` when `role` is a `K_*` role.
    function revokeRole(bytes32 role, address account) public virtual override {
        if (isKeyRole(role) && hasRole(MS_OPS, _msgSender())) {
            _revokeRole(role, account);
            return;
        }
        super.revokeRole(role, account);
    }
}
