// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

/// @dev Forks Arbitrum from $ARB_RPC (default: public endpoint) at a pinned block ($ARB_FORK_BLOCK overrides).
///      Skips the test if the RPC fails or does not serve state at that block: the public node is not an
///      archive node and prunes state after roughly 30 minutes, so later runs need an archive ARB_RPC.
abstract contract ForkUtil is Test {
    string internal constant DEFAULT_ARB_RPC = "https://arb1.arbitrum.io/rpc";
    uint256 internal constant ARB_FORK_BLOCK = 525_105_000; // Arbitrum One, 2026-11-17 17:58:21 UTC

    function _forkArbitrum() internal returns (bool) {
        if (block.chainid == 42161) return true; // already forked via --fork-url
        string memory url = vm.envOr("ARB_RPC", string(DEFAULT_ARB_RPC));
        uint256 blk = vm.envOr("ARB_FORK_BLOCK", ARB_FORK_BLOCK);
        // createSelectFork succeeds even when the state is pruned, and a later state miss is a fatal
        // EVM error, so probe the state with catchable raw RPC calls first (3x: the public endpoint is
        // load-balanced over backends with different retention)
        string memory params = string.concat('["', vm.toString(block.coinbase), '","', _hexQuantity(blk), '"]');
        for (uint256 i; i < 3; i++) {
            try vm.rpc(url, "eth_getBalance", params) {}
            catch {
                return _skip();
            }
        }
        try vm.createSelectFork(url, blk) {}
        catch {
            return _skip();
        }
        return true;
    }

    function _skip() private returns (bool) {
        emit log("ARB_RPC unavailable or state at ARB_FORK_BLOCK not served: skipping fork test");
        vm.skip(true);
        return false;
    }

    /// @dev JSON-RPC quantity: "0x" + hex without leading zeros.
    function _hexQuantity(uint256 v) private pure returns (string memory) {
        if (v == 0) return "0x0";
        uint256 n;
        for (uint256 t = v; t != 0; t >>= 4) n++;
        bytes memory s = new bytes(n + 2);
        s[0] = "0";
        s[1] = "x";
        for (uint256 i = n + 1; i > 1; i--) {
            s[i] = bytes("0123456789abcdef")[v & 15];
            v >>= 4;
        }
        return string(s);
    }
}
