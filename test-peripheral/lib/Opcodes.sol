// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @dev Walks runtime bytecode (skipping PUSH data and the CBOR metadata trailer) and
///      reports the first DELEGATECALL, CALLCODE, SELFDESTRUCT, CREATE or CREATE2.
library Opcodes {
    function findForbidden(bytes memory code) internal pure returns (bool found, uint256 pos, uint8 op) {
        uint256 end = code.length;
        if (end >= 2) {
            uint256 metaLen = (uint256(uint8(code[end - 2])) << 8) | uint8(code[end - 1]);
            if (metaLen + 2 <= end) end -= metaLen + 2;
        }
        for (uint256 i; i < end; ++i) {
            op = uint8(code[i]);
            if (op == 0xf0 || op == 0xf2 || op == 0xf4 || op == 0xf5 || op == 0xff) return (true, i, op);
            if (op >= 0x60 && op <= 0x7f) i += op - 0x5f;
        }
        return (false, 0, 0);
    }
}
