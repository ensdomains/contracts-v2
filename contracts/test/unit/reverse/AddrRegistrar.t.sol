// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {
    AddrRegistrar,
    ROLE_SET,
    ROLE_SET_ADMIN,
    InvalidOwner
} from "~src/reverse/AddrRegistrar.sol";
import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract AddrRegistrarTest is Test {
    MockHCAFactoryBasic hcaFactory;
    AddrRegistrar registrar;

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    string name1 = "user1.eth";
    string name2 = "user2.xyz";

    function setUp() external {
        hcaFactory = new MockHCAFactoryBasic();
        registrar = new AddrRegistrar(hcaFactory);
    }

    function test_reclaim_withName() external {
        vm.expectEmit();
        emit AddrRegistrar.ResourceReplaced(user1, 0, 1);
        vm.expectEmit();
        emit AddrRegistrar.AddrUpdated(user1, name1, address(0), user1);
        vm.prank(user1);
        registrar.reclaim(name1);
        assertEq(registrar.getName(user1), name1, "name");
        assertEq(registrar.getResolver(user1), address(0), "resolver");
        assertTrue(
            registrar.hasRoles(registrar.getResource(user1), ROLE_SET | ROLE_SET_ADMIN, user1),
            "roles"
        );
    }

    function test_reclaim_withResolver() external {
        vm.expectEmit();
        emit AddrRegistrar.ResourceReplaced(user1, 0, 1);
        vm.expectEmit();
        emit AddrRegistrar.AddrUpdated(user1, "", address(1), user1);
        vm.prank(user1);
        registrar.reclaim(address(1));
        assertEq(registrar.getName(user1), "", "name");
        assertEq(registrar.getResolver(user1), address(1), "resolver");
        assertTrue(
            registrar.hasRoles(registrar.getResource(user1), ROLE_SET | ROLE_SET_ADMIN, user1),
            "roles"
        );
    }

    function test_reclaim_withNullName() external {
        registrar.reclaim("");
    }

    function test_reclaim_withNullResolver() external {
        registrar.reclaim(address(0));
    }

    function test_reclaimTo_withName() external {
        vm.expectEmit();
        emit AddrRegistrar.ResourceReplaced(user1, 0, 1);
        vm.expectEmit();
        emit AddrRegistrar.AddrUpdated(user1, name1, address(0), user1);
        vm.prank(user1);
        registrar.reclaimTo(user2, name1);
        assertEq(registrar.getName(user1), name1, "name1"); // set
        assertEq(registrar.getName(user2), "", "name2");
        assertEq(registrar.getResolver(user1), address(0), "resolver1");
        assertEq(registrar.getResolver(user2), address(0), "resolver2");
        uint256 resource = registrar.getResource(user1);
        assertFalse(registrar.hasRoles(resource, ROLE_SET | ROLE_SET_ADMIN, user1), "roles1");
        assertTrue(registrar.hasRoles(resource, ROLE_SET | ROLE_SET_ADMIN, user2), "roles2");
    }

    function test_reclaimTo_withResolver() external {
        vm.expectEmit();
        emit AddrRegistrar.ResourceReplaced(user1, 0, 1);
        vm.expectEmit();
        emit AddrRegistrar.AddrUpdated(user1, "", address(1), user1);
        vm.prank(user1);
        registrar.reclaimTo(user2, address(1));
        assertEq(registrar.getName(user1), "", "name1");
        assertEq(registrar.getName(user2), "", "name2");
        assertEq(registrar.getResolver(user1), address(1), "resolver1"); // set
        assertEq(registrar.getResolver(user2), address(0), "resolver2");
        uint256 resource = registrar.getResource(user1);
        assertFalse(registrar.hasRoles(resource, ROLE_SET | ROLE_SET_ADMIN, user1), "roles1");
        assertTrue(registrar.hasRoles(resource, ROLE_SET | ROLE_SET_ADMIN, user2), "roles2");
    }

    function test_reclaimTo_invalidOwner() external {
        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        registrar.reclaimTo(address(0), name1);
        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        registrar.reclaimTo(address(0), address(1));
    }

    function test_setName() external {
        vm.prank(user1);
        registrar.reclaimTo(user2, name1);
        assertEq(registrar.getName(user1), name1, "before");
        vm.expectEmit();
        emit AddrRegistrar.AddrUpdated(user1, name2, address(0), user2);
        vm.prank(user2);
        registrar.setName(user1, name2);
        assertEq(registrar.getName(user1), name2, "after");
    }

    function test_setName_notAuthorized() external {
        vm.prank(user1);
        registrar.reclaim("");
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registrar.getResource(user1),
                ROLE_SET,
                user2
            )
        );
        vm.prank(user2);
        registrar.setName(user1, name1);
    }

    function test_setResolver() external {
        vm.prank(user1);
        registrar.reclaimTo(user2, address(1));
        assertEq(registrar.getResolver(user1), address(1), "before");
        vm.expectEmit();
        emit AddrRegistrar.AddrUpdated(user1, "", address(2), user2);
        vm.prank(user2);
        registrar.setResolver(user1, address(2));
        assertEq(registrar.getResolver(user1), address(2), "after");
    }

    function test_setResolver_notAuthorized() external {
        vm.prank(user1);
        registrar.reclaim(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registrar.getResource(user1),
                ROLE_SET,
                user2
            )
        );
        vm.prank(user2);
        registrar.setResolver(user1, address(1));
    }

    function test_set_lifecycle() external {
        vm.prank(user1);
        registrar.reclaim(name1);
        assertEq(registrar.getName(user1), name1, "0:name");
        assertEq(registrar.getResolver(user1), address(0), "0:resolver");
        vm.prank(user1);
        registrar.setResolver(user1, address(1));
        assertEq(registrar.getName(user1), "", "1:name");
        assertEq(registrar.getResolver(user1), address(1), "1:resolver");
        vm.prank(user1);
        registrar.setName(user1, name2);
        assertEq(registrar.getName(user1), name2, "2:name");
        assertEq(registrar.getResolver(user1), address(0), "2:resolver");
    }

    function test_authorize() external {
        vm.prank(user1);
        registrar.reclaim(name1);

        // user2 cannot change
        vm.expectRevert();
        vm.prank(user2);
        registrar.setName(user1, name2);
        vm.expectRevert();
        vm.prank(user2);
        registrar.setResolver(user1, address(1));

        // grant user2
        vm.prank(user1);
        registrar.authorize(user1, user2, true);

        // user2 can change
        vm.prank(user2);
        registrar.setName(user1, name2);
        vm.prank(user2);
        registrar.setResolver(user1, address(2));

        // revoke user2
        vm.prank(user1);
        registrar.authorize(user1, user2, false);

        // user2 cannot change
        vm.expectRevert();
        vm.prank(user2);
        registrar.setName(user1, name1);
        vm.expectRevert();
        vm.prank(user2);
        registrar.setResolver(user1, address(1));
    }

    function test_authorize_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                0,
                ROLE_SET,
                user1
            )
        );
        vm.prank(user1);
        registrar.authorize(user1, user2, true);
    }

    function test_getName_unset() external view {
        assertEq(registrar.getName(user1), "");
    }

    function test_getResolver_unset() external view {
        assertEq(registrar.getResolver(user1), address(0));
    }

    function test_getResource_lifecycle() external {
        assertEq(registrar.getResource(user1), 0);
        assertEq(registrar.getResource(user2), 0);
        vm.prank(user1);
        registrar.reclaim(name1);
        assertEq(registrar.getResource(user1), 1);
        assertEq(registrar.getResource(user2), 0);
        vm.prank(user2);
        registrar.reclaim(name2);
        assertEq(registrar.getResource(user1), 1);
        assertEq(registrar.getResource(user2), 2);
    }

    function test_getResourceMax_lifecycle() external {
        assertEq(registrar.getResourceMax(), 0);
        registrar.reclaim("");
        assertEq(registrar.getResourceMax(), 1);
        registrar.reclaim("");
        assertEq(registrar.getResourceMax(), 2);
    }
}
