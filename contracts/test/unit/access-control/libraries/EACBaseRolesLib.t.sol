// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";

contract EACBaseRolesLibTest is Test {
    function test_withAdminRolesApplied() external pure {
        assertEq(EACBaseRolesLib.withAdminRolesApplied(EACBaseRolesLib.ALL_ROLES >> 128), 0);
        assertEq(
            EACBaseRolesLib.withAdminRolesApplied(EACBaseRolesLib.ADMIN_ROLES),
            EACBaseRolesLib.ALL_ROLES
        );
    }

    function test_withAdminRolesApplied(uint8 i) external pure {
        vm.assume(i >= 32 && i < 64);
        uint256 roleBitmap = 1 << (i << 2); // admin bit
        assertEq(
            EACBaseRolesLib.withAdminRolesApplied(roleBitmap | (EACBaseRolesLib.ALL_ROLES >> 128)),
            roleBitmap | (roleBitmap >> 128)
        );
    }

    function test_fromCounts() external pure {
        assertEq(EACBaseRolesLib.fromCounts(0x0123456789abcdef), 0x111111111111111);
    }

    function test_fromCounts(uint8 i) external pure {
        vm.assume(i > 0 && i < 16);
        assertEq(
            EACBaseRolesLib.fromCounts(EACBaseRolesLib.ALL_ROLES * i),
            EACBaseRolesLib.ALL_ROLES
        );
    }

    function test_hasZeroNybbles() external pure {
        assertFalse(EACBaseRolesLib.hasZeroNybbles(EACBaseRolesLib.ALL_ROLES));
    }

    function test_hasZeroNybbles(uint8 i) external pure {
        vm.assume(i < 64);
        assertTrue(EACBaseRolesLib.hasZeroNybbles(~(0xF << (i << 2))));
    }
}
