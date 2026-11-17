// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockVault, MockEVC, MockSanctions} from "./Mocks.sol";
import {HubGuard} from "../../src/peripheral/HubGuard.sol";
import {IEVCSubset} from "../../src/peripheral/interfaces/IEVCSubset.sol";
import {ISanctionsList} from "../../src/peripheral/interfaces/ISanctionsList.sol";
import {EVKOps} from "../../src/peripheral/interfaces/IEVaultHook.sol";

abstract contract P1Base is Test {
    uint32 internal constant HUB_OPS = EVKOps.OP_BORROW | EVKOps.OP_FLASHLOAN | EVKOps.OP_DEPOSIT | EVKOps.OP_MINT
        | EVKOps.OP_SKIM | EVKOps.OP_VAULT_STATUS_CHECK;
    uint32 internal constant ALL_OPS = (1 << 15) - 1;
    uint128 internal constant LIMIT = 1_000e6;
    uint32 internal constant WINDOW = 1 hours;
    uint16 internal constant FEE = 50; // 0.5%

    MockEVC internal evc;
    MockSanctions internal sanc;
    MockVault internal hub;
    HubGuard internal g;

    address internal ops = makeAddr("msOps");
    address internal guardian = makeAddr("guardian");
    address internal denylister = makeAddr("denylister");
    address internal feeRcv = makeAddr("feeReceiver");
    address internal user = makeAddr("user");

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        evc = new MockEVC();
        sanc = new MockSanctions();
        hub = new MockVault(address(0));
        g = new HubGuard(IEVCSubset(address(evc)), ISanctionsList(address(sanc)), 100, 7 days, ops, guardian, denylister);
        hub.setHookConfig(address(g), HUB_OPS);
        vm.prank(ops);
        g.setHub(address(hub), LIMIT, WINDOW, FEE, feeRcv, 1); // FLASH_ON
    }

    function _fee(uint256 x) internal pure returns (uint256) {
        return (x * FEE + 9_999) / 10_000;
    }

    function _b(uint256 x, address r) internal pure returns (bytes memory) {
        return abi.encodeCall(MockVault.borrow, (x, r));
    }

    function _calls(bytes memory a) internal pure returns (bytes[] memory c) {
        c = new bytes[](1);
        c[0] = a;
    }

    function _calls(bytes memory a, bytes memory b) internal pure returns (bytes[] memory c) {
        c = new bytes[](2);
        (c[0], c[1]) = (a, b);
    }

    /// @dev Borrow `x` to `who` plus `fee` to the fee receiver in one atomic batch.
    function _borrowCalls(address who, uint256 x, uint256 fee) internal view returns (bytes[] memory) {
        return fee == 0 ? _calls(_b(x, who)) : _calls(_b(x, who), _b(fee, feeRcv));
    }

    function _batch(address who, uint256 x, uint256 fee) internal {
        vm.prank(who);
        hub.batch(_borrowCalls(who, x, fee));
    }

    function _batchReverts(address who, bytes[] memory calls, bytes memory err) internal {
        vm.prank(who);
        vm.expectRevert(err);
        hub.batch(calls);
    }

    function _arr(address a) internal pure returns (address[] memory r) {
        r = new address[](1);
        r[0] = a;
    }
}
