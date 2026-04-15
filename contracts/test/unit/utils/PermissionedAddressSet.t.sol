// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {
    PermissionedAddressSet,
    ROLE_APPROVE,
    ROLE_APPROVE_ADMIN
} from "~src/utils/PermissionedAddressSet.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract PermissionedAddressSetTest is Test {
    MockHCAFactoryBasic hcaFactory;
    PermissionedAddressSet set;

    address testAddr = makeAddr("something");
    address friend = makeAddr("anotherAdmin");

    function setUp() external {
        hcaFactory = new MockHCAFactoryBasic();
        set = new PermissionedAddressSet(hcaFactory, address(this));
    }

    function test_approve_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                set.ROOT_RESOURCE(),
                ROLE_APPROVE,
                friend
            )
        );
        vm.prank(friend);
        set.approve(testAddr, true);
    }

    function test_approve_unchanged() external {
        vm.expectRevert();
        set.approve(testAddr, false);
    }

    function test_approve() external {
        assertFalse(set.includes(testAddr));

        vm.expectEmit();
        emit PermissionedAddressSet.ApprovalChanged(testAddr, true, address(this));
        set.approve(testAddr, true);

        assertTrue(set.includes(testAddr));

        vm.expectEmit();
        emit PermissionedAddressSet.ApprovalChanged(testAddr, false, address(this));
        set.approve(testAddr, false);

        assertFalse(set.includes(testAddr));
    }

    function test_approve_multiple(bool[] calldata approved) external {
        for (uint160 i; i < approved.length; ++i) {
            if (approved[i]) {
                set.approve(address(i), true);
            }
        }
        for (uint160 i; i < approved.length; ++i) {
            assertEq(set.includes(address(i)), approved[i]);
        }
    }

    function test_approve_granted() external {
        vm.expectRevert();
        vm.prank(friend);
        set.approve(testAddr, true);

        set.grantRootRoles(ROLE_APPROVE, friend);

        vm.prank(friend);
        set.approve(testAddr, true);
    }
}
