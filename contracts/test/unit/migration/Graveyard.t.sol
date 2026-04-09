// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {console} from "forge-std/console.sol";

import {MigrationControllerFixture, NameCoder} from "./MigrationControllerFixture.sol";

contract GraveyardTest is MigrationControllerFixture {
    function setUp() public override {
        super.setUp();
        ethRegistrarV1.addController(address(graveyard));
    }

    function test_clear_example_registered() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped("test");
        bytes32 node = NameCoder.namehash(name, 0);

        vm.prank(user);
        registryV1.setResolver(node, address(1));

        bytes32[] memory ls = new bytes32[](1);
        bytes32[] memory ps = new bytes32[](1);

        ls[0] = bytes32(tokenId);
        ps[0] = NameCoder.ETH_NODE;

        vm.expectRevert();
        graveyard.clear(ps, ls);

        vm.warp(ethRegistrarV1.nameExpires(tokenId) + ethRegistrarV1.GRACE_PERIOD() + 1);

        graveyard.clear(ps, ls);

        assertEq(registryV1.resolver(node), address(0));
    }

    function test_clear_example_deep() external {
        bytes memory name = NameCoder.encode("a.bb.ccc.dddd.eeeee.eth");
        _claimNodes(name, 0, user);

        uint256 count = NameCoder.countLabels(name, 0) - 1; // drop eth
        bytes32[] memory ls = new bytes32[](count);
        bytes32[] memory ps = new bytes32[](count);

        uint256 offset;
        bytes32 node = NameCoder.namehash(name, offset);

        while (node != NameCoder.ETH_NODE) {
            vm.prank(user);
            registryV1.setResolver(node, address(1));
            (ls[--count], offset) = NameCoder.readLabel(name, offset);
            ps[count] = node = NameCoder.namehash(name, offset);
        }

        graveyard.clear(ps, ls);

        for (uint256 i; i < ls.length; ++i) {
            assertEq(registryV1.resolver(NameCoder.namehash(ps[i], ls[i])), address(0));
        }
    }

    function test_clear_wide(uint8 count) external {
        bytes32[] memory ls = new bytes32[](count);
        bytes32[] memory ps = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            ls[i] = bytes32(i);
            ps[i] = NameCoder.ETH_NODE;
        }

        graveyard.clear(ps, ls);
    }

    function test_clear_deep(uint8 depth) external {
        bytes32[] memory ls = new bytes32[](depth);
        bytes32[] memory ps = new bytes32[](depth);
        bytes32 parent = NameCoder.ETH_NODE;
        for (uint256 i; i < depth; ++i) {
            bytes32 labelHash = bytes32(i);
            ls[i] = labelHash;
            ps[i] = parent;
            parent = NameCoder.namehash(parent, labelHash);
        }

        graveyard.clear(ps, ls);
    }
}
