// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {CAN_DO_EVERYTHING, CANNOT_UNWRAP} from "@ens/contracts/wrapper/INameWrapper.sol";

import {MigrationControllerFixture, NameCoder} from "./MigrationControllerFixture.sol";

contract GraveyardTest is MigrationControllerFixture {
    function setUp() public override {
        super.setUp();
        ethRegistrarV1.addController(address(graveyard));
    }

    function test_clearUnwrapped_example_registered() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped("test");
        bytes32 node = NameCoder.namehash(name, 0);

        vm.prank(user);
        registryV1.setResolver(node, address(1));

        bytes32[] memory ls = new bytes32[](1);
        bytes32[] memory ps = new bytes32[](1);

        ls[0] = bytes32(tokenId);
        ps[0] = NameCoder.ETH_NODE;

        vm.expectRevert();
        graveyard.clearUnwrapped(ps, ls);

        vm.warp(ethRegistrarV1.nameExpires(tokenId) + ethRegistrarV1.GRACE_PERIOD() + 1);

        graveyard.clearUnwrapped(ps, ls);

        assertEq(registryV1.resolver(node), address(0));
    }

    function test_clearUnwrapped_example_transferred() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped("test");
        bytes32 node = NameCoder.namehash(name, 0);

        vm.prank(user);
        registryV1.setResolver(node, address(1));

        bytes32[] memory ls = new bytes32[](1);
        bytes32[] memory ps = new bytes32[](1);

        ls[0] = bytes32(tokenId);
        ps[0] = NameCoder.ETH_NODE;

        vm.expectRevert();
        graveyard.clearUnwrapped(ps, ls);

        // do migration logic
        vm.prank(user);
        registryV1.setOwner(node, address(graveyard));
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(user, address(graveyard), tokenId);

        graveyard.clearUnwrapped(ps, ls);

        assertEq(registryV1.resolver(node), address(0));
    }

    function test_clearUnwrapped_example_deep() external {
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

        graveyard.clearUnwrapped(ps, ls);

        for (uint256 i; i < ls.length; ++i) {
            assertEq(registryV1.resolver(NameCoder.namehash(ps[i], ls[i])), address(0));
        }
    }

    function test_clearUnwrapped_wide(uint8 count) external {
        bytes32[] memory ls = new bytes32[](count);
        bytes32[] memory ps = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            ls[i] = bytes32(i);
            ps[i] = NameCoder.ETH_NODE;
        }

        graveyard.clearUnwrapped(ps, ls);
    }

    function test_clearUnwrapped_deep(uint8 depth) external {
        bytes32[] memory ls = new bytes32[](depth);
        bytes32[] memory ps = new bytes32[](depth);
        bytes32 parent = NameCoder.ETH_NODE;
        for (uint256 i; i < depth; ++i) {
            bytes32 labelHash = bytes32(i);
            ls[i] = labelHash;
            ps[i] = parent;
            parent = NameCoder.namehash(parent, labelHash);
        }

        graveyard.clearUnwrapped(ps, ls);
    }

    function test_clearWrappedChildren_example() external {
        bytes memory name2 = registerWrappedETH2LD("test", CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(name2, "sub", user, CAN_DO_EVERYTHING);
        bytes memory name4 = createWrappedChild(name3, "abc", user, CAN_DO_EVERYTHING);

        // name2 resolver would be cleared by migration

        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(3));
        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name4, 0), address(4));

        // unwrap name4
        vm.prank(user);
        nameWrapper.unwrap(
            NameCoder.namehash(name3, 0),
            keccak256(bytes(NameCoder.firstLabel(name4))),
            address(graveyard)
        );

        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(graveyard),
            uint256(NameCoder.namehash(name2, 0)),
            1,
            ""
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(graveyard),
            uint256(NameCoder.namehash(name3, 0)),
            1,
            ""
        );

        // clear name3
        string[] memory ss = new string[](1);
        bytes32[] memory ps = new bytes32[](1);
        ss[0] = NameCoder.firstLabel(name3);
        ps[0] = NameCoder.namehash(name2, 0);
        graveyard.clearWrappedChildren(ps, ss);

        // clear name4
        bytes32[] memory ls = new bytes32[](1);
        ls[0] = keccak256(bytes(NameCoder.firstLabel(name4)));
        ps[0] = NameCoder.namehash(name3, 0);
        graveyard.clearUnwrapped(ps, ls);

        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0), "3");
        assertEq(registryV1.resolver(NameCoder.namehash(name4, 0)), address(0), "4");
    }
}
