// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IHookTarget} from "evk/interfaces/IHookTarget.sol";

/// @notice Stand-in for `PoppieEscrowHook` until it lands: a valid EVK hook target that allows every hooked
/// operation. Lets tests install the expected escrow hook config (`ESCROW_HOOKED_OPS`) on an escrow vault.
contract MockEscrowHook is IHookTarget {
    function isHookTarget() external pure returns (bytes4) {
        return IHookTarget.isHookTarget.selector;
    }

    fallback() external {}
}
