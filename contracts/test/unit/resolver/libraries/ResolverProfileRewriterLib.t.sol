// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test, stdError} from "forge-std/Test.sol";

import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";

import {ResolverProfileRewriterLib} from "~src/resolver/libraries/ResolverProfileRewriterLib.sol";

contract ResolverProfileRewriterLibTest is Test {
    bytes vMin = abi.encodeCall(this.resolverProfile, bytes32(0)); // 36 bytes
    bytes vBad = new bytes(vMin.length - 1);

    function resolverProfile(bytes32) external {}

    function replaceNode(bytes calldata call, bytes32 node) external pure returns (bytes memory) {
        return ResolverProfileRewriterLib.replaceNode(call, node);
    }

    function drop4(bytes calldata v) external pure returns (bytes memory) {
        return v[4:];
    }

    function testFuzz_replaceNode_call(bytes32 node) external view {
        assertEq(
            abi.decode(
                this.drop4(
                    this.replaceNode(abi.encodeCall(this.resolverProfile, (keccak256("a"))), node)
                ),
                (bytes32)
            ),
            node
        );
    }

    function test_replaceNode_call_smallestWrite(bytes32 node) external view {
        assertEq(bytes32(this.drop4(this.replaceNode(vMin, node))), node);
    }

    function test_replaceNode_call_outOfBounds(bytes32 node) external view {
        assertEq(this.replaceNode(vBad, node), vBad); // unchanged
    }

    function testFuzz_replaceNode_multicall(bytes32 node, uint8 calls) external view {
        bytes[] memory m = new bytes[](calls);
        for (uint256 i; i < calls; i++) {
            m[i] = abi.encodeCall(this.resolverProfile, (keccak256("a")));
        }
        m = abi.decode(
            this.drop4(this.replaceNode(abi.encodeCall(IMulticallable.multicall, (m)), node)),
            (bytes[])
        );
        assertEq(m.length, calls);
        for (uint256 i; i < calls; i++) {
            assertEq(abi.decode(this.drop4(m[i]), (bytes32)), node);
        }
    }

    function test_replaceNode_multicall_smallestWrite(bytes32 node) external view {
        bytes[] memory m = new bytes[](1);
        m[0] = vMin;
        m = abi.decode(
            this.drop4(this.replaceNode(abi.encodeCall(IMulticallable.multicall, (m)), node)),
            (bytes[])
        );
        assertEq(bytes32(this.drop4(m[0])), node);
    }

    function test_replaceNode_multicall_outOfBounds(bytes32 node) external view {
        bytes[] memory m = new bytes[](1);
        m[0] = vBad;
        bytes memory v0 = abi.encodeCall(IMulticallable.multicall, (m));
        bytes memory v = this.replaceNode(v0, node);
        assertEq(v0, v); // unchanged
    }

    function test_replaceNode_multicall_outOfBounds_arrayStart(bytes32 node) external view {
        bytes[] memory m = new bytes[](1);
        m[0] = vMin;
        bytes memory v0 = abi.encodeCall(IMulticallable.multicall, (m));
        uint256 offset = 100; // offset of first element
        uint256 save;
        bytes memory v = abi.encodePacked(v0);
        assembly {
            save := mload(add(v, offset))
            mstore(add(v, offset), mload(v)) // mangle
        }
        v = this.replaceNode(v, node);
        assembly {
            mstore(add(v, offset), save) // unmangle
        }
        assertEq(v0, v); // unchanged
    }

    function testFuzz_replaceNode_nestedMulticall(bytes32 node, uint8 depth) external view {
        vm.assume(depth < 10);
        bytes memory v = abi.encodeCall(this.resolverProfile, (keccak256("a")));
        bytes[] memory m = new bytes[](1);
        for (uint256 i; i < depth; ++i) {
            m[0] = v;
            v = abi.encodeCall(IMulticallable.multicall, (m));
        }
        v = this.replaceNode(v, node);
        for (uint256 i; i < depth; ++i) {
            m = abi.decode(this.drop4(v), (bytes[]));
            v = m[0];
        }
        assertEq(abi.decode(this.drop4(v), (bytes32)), node);
    }
}
