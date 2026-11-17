// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Opcodes} from "../lib/Opcodes.sol";

contract DelegateFixture {
    function f(address t) external returns (bool ok) {
        (ok,) = t.delegatecall("");
    }
}

contract CleanFixture {
    // PUSH32 data containing 0xf4/0xff bytes must not be flagged.
    bytes32 internal constant K = 0xf4f4f4f4ff00ff00f5f5f0f0f2f2f4f4f4f4ff00ff00f5f5f0f0f2f2f4f4ff00;

    function f() external pure returns (bytes32) {
        return K;
    }
}

contract OpcodesSelfTest is Test {
    function test_flagsDelegatecall() public {
        (bool found,, uint8 op) = Opcodes.findForbidden(address(new DelegateFixture()).code);
        assertTrue(found);
        assertEq(op, 0xf4);
    }

    function test_passesClean() public {
        (bool found,,) = Opcodes.findForbidden(address(new CleanFixture()).code);
        assertFalse(found);
    }

    function test_flagsRawSelfdestruct() public pure {
        (bool found,, uint8 op) = Opcodes.findForbidden(hex"6001ff0000"); // PUSH1 1, SELFDESTRUCT, + 0-length trailer
        assertTrue(found);
        assertEq(op, 0xff);
    }

    function test_skipsPushData() public pure {
        (bool found,,) = Opcodes.findForbidden(hex"61f4ff000000"); // PUSH2 0xf4ff, STOP, trailer len 0
        assertFalse(found);
    }
}
