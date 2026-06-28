// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {PermissionedResolverLib} from "~src/resolver/libraries/PermissionedResolverLib.sol";

contract PermissionedResolverLibTest is Test {
    function test_anySetter(bytes calldata name) external {
        assertEq(PermissionedResolverLib.anySetter(name), abi.encodeWithSelector(bytes4(0), name));
    }

    function test_resource_root_default() external {
        assertEq(PermissionedResolverLib.resource(0), 0);
    }

    function test_resource_root() external {
        assertEq(PermissionedResolverLib.resource(0, 0), 0);
    }

    function test_resource_notRoot_default(uint256 recordId) external {
        vm.assume(recordId > 0);
        assertNotEq(PermissionedResolverLib.resource(recordId), 0);
    }

    function test_resource_notRoot(uint256 recordId, bytes32 part) external {
        vm.assume(recordId > 0 || part != bytes32(0));
        assertNotEq(PermissionedResolverLib.resource(recordId, part), 0);
    }

    function test_partHash_string(string calldata s) external {
        assertEq(PermissionedResolverLib.partHash(s), keccak256(abi.encodePacked(s)));
    }

    function test_partHash_uint256(uint256 x) external {
        assertEq(PermissionedResolverLib.partHash(x), keccak256(abi.encode(x)));
    }

    function test_partHash_bytes4(bytes4 x) external {
        assertEq(PermissionedResolverLib.partHash(x), keccak256(abi.encode(uint32(x))));
    }
}
