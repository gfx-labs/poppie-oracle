// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test, console} from "forge-std/Test.sol";

import {PoppieEulerOracle} from "../../src/oracle/PoppieEulerOracle.sol";
import {IPoppieEulerOracle} from "../../src/interfaces/IPoppieEulerOracle.sol";
import {PackedPrices} from "../../src/oracle/PackedPrices.sol";
import {MS_OPS, K_PRICE, K_CONFIRM} from "../../src/access/Roles.sol";

/// @dev Runtime code etched at token addresses: `decimals()` returns 18 and nothing else works.
contract Decimals18 {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

/// @notice Push gas benchmarks for 100 / 250 / 500 assets in both formats (V2_PLAN.md section 8, CONTRACT_SPEC.md
/// section 6 "Scale"), and a 500-asset `confirmBatch`. Numbers are printed with `-vv`; every scenario also has a
/// ceiling so a regression fails the suite.
///
/// Reported gas is the execution gas of the call plus the calldata cost and the 21k base, i.e. what the
/// transaction would use, ignoring L1 data pricing (Arbitrum charges L1 data separately, which is what the packed
/// format is for). A plain `forge test` runs the whole test as one transaction, so storage warmed earlier in the
/// test is cheaper than in production; run `forge test --isolate --match-path test/bench/PushGas.t.sol -vv` for
/// cold-storage numbers (the ceilings below are set from that run).
contract PushGasTest is Test {
    uint256 internal constant T0 = 1_000_000;
    uint256 internal constant MAX_N = 500;

    address internal admin = makeAddr("admin");
    address internal keeper = makeAddr("keeper");
    address internal confirmer = makeAddr("confirmer");
    address internal ops = makeAddr("ops");

    PoppieEulerOracle internal oracle;
    address[] internal tokens;

    function setUp() public {
        vm.warp(T0);
        oracle = new PoppieEulerOracle(admin);
        vm.startPrank(admin);
        oracle.grantRole(K_PRICE, keeper);
        oracle.grantRole(K_CONFIRM, confirmer);
        oracle.grantRole(MS_OPS, ops);
        vm.stopPrank();

        address code = address(new Decimals18());
        address[] memory ts = new address[](MAX_N);
        IPoppieEulerOracle.PriceClass[] memory cs = new IPoppieEulerOracle.PriceClass[](MAX_N);
        for (uint256 i; i < MAX_N; ++i) {
            address t = address(uint160(0xA000_0000 + i));
            vm.etch(t, code.code);
            ts[i] = t;
            cs[i] = IPoppieEulerOracle.PriceClass(i % 4);
            tokens.push(t);
        }
        vm.prank(ops);
        oracle.listAssets(ts, cs);
    }

    // -- Helpers ---------------------------------------------------------------------------------

    function _price(uint256 i, uint256 round) internal pure returns (uint128) {
        // Different price per asset and round; always within 1% of the previous round for the same asset.
        return uint128((100 + (i % 50)) * 1e18 + round * 1e15);
    }

    function _abiCall(uint256 n, uint256 round, uint256 multiplier) internal view returns (bytes memory) {
        address[] memory as_ = new address[](n);
        uint128[] memory ps = new uint128[](n);
        for (uint256 i; i < n; ++i) {
            as_[i] = tokens[i];
            ps[i] = uint128(uint256(_price(i, round)) * multiplier);
        }
        return abi.encodeCall(oracle.keeperPushPrices, (as_, ps));
    }

    function _packedCall(uint256 n, uint256 round, uint256 multiplier) internal view returns (bytes memory) {
        bytes memory data;
        for (uint256 i; i < n; ++i) {
            data = bytes.concat(
                data, PackedPrices.encode(oracle.assetId(tokens[i]), uint96(uint256(_price(i, round)) * multiplier))
            );
        }
        return abi.encodeCall(oracle.keeperPushPacked, (data));
    }

    function _calldataGas(bytes memory data) internal pure returns (uint256 g) {
        for (uint256 i; i < data.length; ++i) {
            g += data[i] == 0 ? 4 : 16;
        }
    }

    /// @dev Runs the call as `who`, returns execution gas.
    function _measure(address who, address target, bytes memory callData) internal returns (uint256 used) {
        // Cold access: earlier calls in this test warmed the oracle's slots, a real transaction starts cold.
        vm.cool(target);
        vm.prank(who);
        uint256 before = gasleft();
        (bool ok,) = target.call(callData);
        used = before - gasleft();
        require(ok, "bench call reverted");
    }

    function _report(string memory what, uint256 n, bytes memory callData, uint256 exec) internal pure {
        uint256 total = exec + _calldataGas(callData) + 21_000;
        console.log(what);
        console.log("  assets", n);
        console.log("  calldata bytes", callData.length);
        console.log("  tx gas", total);
        console.log("  gas per asset", total / n);
    }

    function _sizes() internal pure returns (uint256[3] memory) {
        return [uint256(100), 250, 500];
    }

    /// @dev Bring the first `n` assets to Live at `_price(i, 0)` (push + confirm), then move time on so the next
    /// push is a normal refresh.
    function _goLive(uint256 n) internal {
        vm.prank(keeper);
        (bool ok,) = address(oracle).call(_abiCall(n, 0, 1));
        require(ok, "push");
        address[] memory as_ = new address[](n);
        uint128[] memory ps = new uint128[](n);
        for (uint256 i; i < n; ++i) {
            as_[i] = tokens[i];
            ps[i] = _price(i, 0);
        }
        vm.prank(confirmer);
        oracle.confirmBatch(as_, ps);
        vm.warp(block.timestamp + 1 minutes);
    }

    // -- Scenarios -------------------------------------------------------------------------------

    /// @dev Steady state: every asset is Live and the push is inside its bound. One hot-slot write each.
    function test_gas_liveRefresh_abi() public {
        uint256[3] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            uint256 snap = vm.snapshotState();
            _goLive(n);
            bytes memory data = _abiCall(n, 1, 1);
            uint256 exec = _measure(keeper, address(oracle), data);
            _report("live refresh, ABI", n, data, exec);
            assertLt(exec / n, 14_000, "live refresh ABI: gas per asset");
            vm.revertToState(snap);
        }
    }

    function test_gas_liveRefresh_packed() public {
        uint256[3] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            uint256 snap = vm.snapshotState();
            _goLive(n);
            bytes memory data = _packedCall(n, 1, 1);
            uint256 exec = _measure(keeper, address(oracle), data);
            _report("live refresh, packed", n, data, exec);
            assertEq(data.length, 4 + 32 + 32 + ((n * 14 + 31) / 32) * 32);
            assertLt(exec / n, 17_000, "live refresh packed: gas per asset");
            vm.revertToState(snap);
        }
    }

    /// @dev First price for every asset (`L == 0`): hot slot update plus a fresh pending slot each.
    function test_gas_firstPush_abi() public {
        uint256[3] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            uint256 snap = vm.snapshotState();
            bytes memory data = _abiCall(n, 0, 1);
            uint256 exec = _measure(keeper, address(oracle), data);
            _report("first push (L == 0), ABI", n, data, exec);
            assertLt(exec / n, 40_000, "first push ABI: gas per asset");
            vm.revertToState(snap);
        }
    }

    function test_gas_firstPush_packed() public {
        uint256[3] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            uint256 snap = vm.snapshotState();
            bytes memory data = _packedCall(n, 0, 1);
            uint256 exec = _measure(keeper, address(oracle), data);
            _report("first push (L == 0), packed", n, data, exec);
            assertLt(exec / n, 42_000, "first push packed: gas per asset");
            vm.revertToState(snap);
        }
    }

    /// @dev Worst case for a live market: every asset jumps beyond its bound (x3), so each starts a pending move.
    function test_gas_allBeyondBound_abi() public {
        uint256[3] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            uint256 snap = vm.snapshotState();
            _goLive(n);
            bytes memory data = _abiCall(n, 1, 3);
            uint256 exec = _measure(keeper, address(oracle), data);
            _report("all beyond bound (pending), ABI", n, data, exec);
            assertLt(exec / n, 42_000, "beyond bound ABI: gas per asset");
            vm.revertToState(snap);
        }
    }

    function test_gas_allBeyondBound_packed() public {
        uint256[3] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            uint256 snap = vm.snapshotState();
            _goLive(n);
            bytes memory data = _packedCall(n, 1, 3);
            uint256 exec = _measure(keeper, address(oracle), data);
            _report("all beyond bound (pending), packed", n, data, exec);
            assertLt(exec / n, 44_000, "beyond bound packed: gas per asset");
            vm.revertToState(snap);
        }
    }

    /// @dev 500-asset `confirmBatch` (and the smaller sizes) after a full beyond-bound push.
    function test_gas_confirmBatch() public {
        uint256[3] memory sizes = _sizes();
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            uint256 snap = vm.snapshotState();
            _goLive(n);
            vm.prank(keeper);
            (bool ok,) = address(oracle).call(_abiCall(n, 1, 3));
            require(ok, "push");
            address[] memory as_ = new address[](n);
            uint128[] memory ps = new uint128[](n);
            for (uint256 i; i < n; ++i) {
                as_[i] = tokens[i];
                ps[i] = uint128(uint256(_price(i, 1)) * 3);
            }
            bytes memory data = abi.encodeCall(oracle.confirmBatch, (as_, ps));
            uint256 exec = _measure(confirmer, address(oracle), data);
            _report("confirmBatch", n, data, exec);
            assertLt(exec / n, 18_000, "confirmBatch: gas per asset");
            for (uint256 i; i < n; ++i) {
                assertEq(oracle.getAssetData(tokens[i]).pendingCount, 0);
            }
            vm.revertToState(snap);
        }
    }

    /// @dev Both formats leave identical state for a full 500-asset round.
    function test_formatsAgreeAtScale() public {
        _goLive(MAX_N);
        uint256 snap = vm.snapshotState();
        bytes memory abiData = _abiCall(MAX_N, 1, 1);
        _measure(keeper, address(oracle), abiData);
        bytes32 h1 = _stateHash(MAX_N);
        vm.revertToState(snap);
        bytes memory packedData = _packedCall(MAX_N, 1, 1);
        _measure(keeper, address(oracle), packedData);
        bytes32 h2 = _stateHash(MAX_N);
        assertEq(h1, h2);
    }

    function _stateHash(uint256 n) internal view returns (bytes32 h) {
        for (uint256 i; i < n; ++i) {
            h = keccak256(abi.encode(h, oracle.getAssetData(tokens[i])));
        }
    }
}
