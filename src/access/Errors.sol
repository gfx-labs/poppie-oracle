// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @dev Shared `ZeroAddress()` error, declared at file level so that a contract can use it without declaring it
/// again. Declaring it inside `PoppieAccessControl` made every contract that inherits both that base and an
/// interface declaring the same error fail to compile (solc 9097). Selector: `bytes4(keccak256("ZeroAddress()"))`,
/// identical to the per-interface declarations.
error ZeroAddress();
