// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {PublicResolverV2} from "~src/resolver/PublicResolverV2.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {V1Fixture} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract PublicResolverV2Test is V1Fixture, V2Fixture {
    PublicResolverV2 publicResolver;

    address actor = makeAddr("actor");
    address friend = makeAddr("friend");

    function setUp() external {
        deployV1Fixture();
        deployV2Fixture();
        publicResolver = new PublicResolverV2(hcaFactory, nameWrapper, rootRegistry, contractNamer);
    }

    function test_canModifyName() external {
        bytes32 node = _register("test");

        // call a setter
        vm.prank(testOwner);
        publicResolver.setAddr(node, testOwner);
    }

    function test_canModifyName_setApprovalForAll() external {
        bytes32 node = _register("test");

        vm.prank(testOwner);
        publicResolver.setApprovalForAll(friend, true);

        assertTrue(publicResolver.canModifyName(node, friend));

        // call a setter
        vm.prank(friend);
        publicResolver.setAddr(node, testOwner);
    }

    function test_canModifyName_approve() external {
        bytes32 node = _register("test");

        vm.prank(testOwner);
        publicResolver.approve(node, friend, true);

        assertTrue(publicResolver.canModifyName(node, friend));
        assertFalse(publicResolver.canModifyName(~node, friend));

        // call a setter
        vm.prank(friend);
        publicResolver.setAddr(node, testOwner);
    }

    function test_canModifyName_notAuthorized(bytes32 node) external {
        assertFalse(publicResolver.canModifyName(node, testOwner));

        // call a setter
        vm.expectRevert();
        vm.prank(actor);
        publicResolver.setAddr(node, testOwner);
    }

    function _register(string memory label) internal returns (bytes32 node) {
        // register wrapped name in v1
        bytes memory name = registerWrappedETH2LD(label, 0);
        node = NameCoder.namehash(name, 0);

        assertFalse(publicResolver.canModifyName(node, testOwner), "before");

        // register same name in v2
        ethRegistry.register(
            label,
            testOwner,
            IRegistry(address(0)),
            address(publicResolver),
            0,
            uint64(block.timestamp + 1 days)
        );

        assertTrue(publicResolver.canModifyName(node, testOwner), "after");
    }
}
