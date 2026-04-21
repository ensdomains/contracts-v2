// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {PublicResolverV2, NameCoder} from "~src/resolver/PublicResolverV2.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {V1Fixture} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract PublicResolverV2Test is V1Fixture, V2Fixture {
    PublicResolverV2 publicResolver;

    address friend = makeAddr("friend");

    function setUp() external {
        deployV1Fixture();
        deployV2Fixture();
        publicResolver = new PublicResolverV2(hcaFactory, nameWrapper, rootRegistry);
    }

    function test_canModifyName() external {
        bytes32 node = _register("test");

        // call a setter
        vm.prank(user);
        publicResolver.setAddr(node, user);
    }

    function test_canModifyName_setApprovalForAll() external {
        bytes32 node = _register("test");

        vm.prank(user);
        publicResolver.setApprovalForAll(friend, true);

        assertTrue(publicResolver.canModifyName(node, friend));

        // call a setter
        vm.prank(friend);
        publicResolver.setAddr(node, user);
    }

    function test_canModifyName_approve() external {
        bytes32 node = _register("test");

        vm.prank(user);
        publicResolver.approve(node, friend, true);

        assertTrue(publicResolver.canModifyName(node, friend));
        assertFalse(publicResolver.canModifyName(~node, friend));

        // call a setter
        vm.prank(friend);
        publicResolver.setAddr(node, user);
    }

    function test_canModifyName_notAuthorized(bytes32 node) external {
        assertFalse(publicResolver.canModifyName(node, user));

        // call a setter
        vm.expectRevert();
        vm.prank(user);
        publicResolver.setAddr(node, user);
    }

    function _register(string memory label) internal returns (bytes32 node) {
        // register wrapped name in v1
        bytes memory name = this.registerWrappedETH2LD(label, 0);
        node = NameCoder.namehash(name, 0);

        assertFalse(publicResolver.canModifyName(node, user), "before");

        // register same name in v2
        ethRegistry.register(
            label,
            user,
            IRegistry(address(0)),
            address(publicResolver),
            0,
            uint64(block.timestamp + 1 days)
        );

        assertTrue(publicResolver.canModifyName(node, user), "after");
    }
}
