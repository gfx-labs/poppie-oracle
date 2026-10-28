// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {PoppieAccessControl} from "../../src/access/PoppieAccessControl.sol";
import {MS_OPS, K_PRICE, K_CONFIRM, K_TIGHTEN, K_LOOSEN, K_ALLOC, K_GUARD, K_RESERVE} from "../../src/access/Roles.sol";

contract AccessControlHarness is PoppieAccessControl {
    constructor(address timelock) PoppieAccessControl(timelock) {}
}

contract PoppieAccessControlTest is Test {
    AccessControlHarness internal ac;

    address internal timelock = makeAddr("timelock");
    address internal msOps = makeAddr("msOps");
    address internal key = makeAddr("key");
    address internal stranger = makeAddr("stranger");

    bytes32[7] internal keyRoles = [K_PRICE, K_CONFIRM, K_TIGHTEN, K_LOOSEN, K_ALLOC, K_GUARD, K_RESERVE];

    function setUp() public {
        ac = new AccessControlHarness(timelock);
        vm.prank(timelock);
        ac.grantRole(MS_OPS, msOps);
    }

    function test_timelockIsDefaultAdmin() public view {
        assertTrue(ac.hasRole(ac.DEFAULT_ADMIN_ROLE(), timelock));
        assertFalse(ac.hasRole(ac.DEFAULT_ADMIN_ROLE(), msOps));
        assertFalse(ac.hasRole(ac.DEFAULT_ADMIN_ROLE(), address(this)));
    }

    function test_constructorRejectsZeroTimelock() public {
        vm.expectRevert(PoppieAccessControl.ZeroAddress.selector);
        new AccessControlHarness(address(0));
    }

    /// Deploy-script bootstrap: the deployer is the initial admin, grants every role without the timelock
    /// delay, hands DEFAULT_ADMIN_ROLE to the timelock and renounces, ending with no role.
    function test_bootstrapHandoverToTimelock() public {
        address deployer = makeAddr("deployer");
        AccessControlHarness fresh = new AccessControlHarness(deployer);
        bytes32 adminRole = fresh.DEFAULT_ADMIN_ROLE();

        vm.startPrank(deployer);
        fresh.grantRole(MS_OPS, msOps);
        for (uint256 i; i < keyRoles.length; ++i) {
            fresh.grantRole(keyRoles[i], key);
        }
        fresh.grantRole(adminRole, timelock);
        fresh.renounceRole(adminRole, deployer);
        vm.stopPrank();

        assertFalse(fresh.hasRole(adminRole, deployer));
        assertTrue(fresh.hasRole(adminRole, timelock));
        assertTrue(fresh.hasRole(MS_OPS, msOps));
        for (uint256 i; i < keyRoles.length; ++i) {
            assertTrue(fresh.hasRole(keyRoles[i], key));
        }

        // The deployer can no longer grant anything.
        vm.prank(deployer);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, deployer, adminRole)
        );
        fresh.grantRole(K_PRICE, deployer);
    }

    function test_timelockGrantsAndRevokesEveryRole() public {
        for (uint256 i; i < keyRoles.length; ++i) {
            vm.startPrank(timelock);
            ac.grantRole(keyRoles[i], key);
            assertTrue(ac.hasRole(keyRoles[i], key));
            ac.revokeRole(keyRoles[i], key);
            assertFalse(ac.hasRole(keyRoles[i], key));
            vm.stopPrank();
        }
    }

    function test_msOpsCanRevokeEveryKeyRole() public {
        for (uint256 i; i < keyRoles.length; ++i) {
            vm.prank(timelock);
            ac.grantRole(keyRoles[i], key);

            vm.prank(msOps);
            ac.revokeRole(keyRoles[i], key);
            assertFalse(ac.hasRole(keyRoles[i], key));
        }
    }

    function test_msOpsCannotGrantAnyKeyRole() public {
        bytes32 adminRole = ac.DEFAULT_ADMIN_ROLE();
        for (uint256 i; i < keyRoles.length; ++i) {
            vm.prank(msOps);
            vm.expectRevert(
                abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, msOps, adminRole)
            );
            ac.grantRole(keyRoles[i], key);
        }
    }

    function test_msOpsCannotGrantOrRevokeNonKeyRoles() public {
        bytes32 adminRole = ac.DEFAULT_ADMIN_ROLE();

        vm.startPrank(msOps);
        vm.expectRevert();
        ac.grantRole(MS_OPS, key);
        vm.expectRevert();
        ac.grantRole(adminRole, key);
        // Cannot remove the timelock or itself-by-proxy: only key roles are revocable by MS_OPS.
        vm.expectRevert();
        ac.revokeRole(adminRole, timelock);
        vm.stopPrank();

        assertTrue(ac.hasRole(adminRole, timelock));
    }

    function test_keyHolderCannotRevokeOtherKeys() public {
        vm.startPrank(timelock);
        ac.grantRole(K_PRICE, key);
        ac.grantRole(K_GUARD, stranger);
        vm.stopPrank();

        vm.prank(key);
        vm.expectRevert();
        ac.revokeRole(K_GUARD, stranger);
        assertTrue(ac.hasRole(K_GUARD, stranger));
    }

    function test_strangerCannotRevoke() public {
        vm.prank(timelock);
        ac.grantRole(K_PRICE, key);

        vm.prank(stranger);
        vm.expectRevert();
        ac.revokeRole(K_PRICE, key);
        assertTrue(ac.hasRole(K_PRICE, key));
    }

    function test_revokedMsOpsLosesRevokePower() public {
        vm.startPrank(timelock);
        ac.grantRole(K_PRICE, key);
        ac.revokeRole(MS_OPS, msOps);
        vm.stopPrank();

        vm.prank(msOps);
        vm.expectRevert();
        ac.revokeRole(K_PRICE, key);
    }

    function test_isKeyRole() public view {
        for (uint256 i; i < keyRoles.length; ++i) {
            assertTrue(ac.isKeyRole(keyRoles[i]));
        }
        assertFalse(ac.isKeyRole(MS_OPS));
        assertFalse(ac.isKeyRole(ac.DEFAULT_ADMIN_ROLE()));
    }

    function testFuzz_isKeyRoleOnlyForKeyRoles(bytes32 role) public view {
        bool expected;
        for (uint256 i; i < keyRoles.length; ++i) {
            if (role == keyRoles[i]) expected = true;
        }
        assertEq(ac.isKeyRole(role), expected);
    }
}
