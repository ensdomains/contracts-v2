// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {MigrationControllerFixture, NameCoder} from "./MigrationControllerFixture.sol";

contract GraveyardTest is MigrationControllerFixture {
    function setUp() public override {
        super.setUp();
        ethRegistrarV1.addController(address(graveyard));
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
