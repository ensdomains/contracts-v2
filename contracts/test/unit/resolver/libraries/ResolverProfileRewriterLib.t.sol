// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test, console, stdError} from "forge-std/Test.sol";

import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";

import {ResolverProfileRewriterLib} from "~src/resolver/libraries/ResolverProfileRewriterLib.sol";

contract ResolverProfileRewriterLibTest is Test {
    function replaceNode(bytes calldata call, bytes32 node) external pure returns (bytes memory) {
        return ResolverProfileRewriterLib.replaceNode(call, node);
    }

    function drop4(bytes calldata v) external pure returns (bytes memory) {
        return v[4:];
    }

    function resolverProfile(bytes32) external {}

    function testFuzz_replaceNode_call(bytes32 node) external view {
        bytes32 x = abi.decode(
            this.drop4(
                this.replaceNode(abi.encodeCall(this.resolverProfile, (keccak256("a"))), node)
            ),
            (bytes32)
        );
        assertEq(x, node, "node");
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
        assertEq(m.length, calls, "count");
        for (uint256 i; i < calls; i++) {
            bytes32 x = abi.decode(this.drop4(m[i]), (bytes32));
            assertEq(x, node, "node");
        }
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
        bytes32 x = abi.decode(this.drop4(v), (bytes32));
        assertEq(x, node, "node");
    }

    function test_replaceNode_call_outOfBounds() external {
        this.replaceNode(new bytes(36), bytes32(0)); // min
        vm.expectRevert(stdError.indexOOBError);
        this.replaceNode(new bytes(35), bytes32(0)); // min-1
    }

    function test_replaceNode_multicall_outOfBounds() external {
        bytes[] memory m = new bytes[](1);
        m[0] = new bytes(36); // min from above
        this.replaceNode(abi.encodeCall(IMulticallable.multicall, (m)), bytes32(0));

        // malicious array[0] start
        bytes memory v = abi.encodeCall(IMulticallable.multicall, (m));
        assembly {
            mstore(add(v, 100), mload(v))
        }
        vm.expectRevert(stdError.indexOOBError);
        this.replaceNode(v, bytes32(0));

        // malicious array[0] size
        m[0] = new bytes(35); // min-1 from above
        vm.expectRevert(stdError.indexOOBError);
        this.replaceNode(abi.encodeCall(IMulticallable.multicall, (m)), bytes32(0));
    }
}
