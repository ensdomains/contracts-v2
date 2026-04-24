// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";

import {
    ResolverProfileRewriterLib
} from "~src/resolver/libraries/ResolverProfileRewriterLib.sol";

contract ResolverProfileRewriterLibTest is Test {
    function replaceNode(bytes calldata call, bytes32 node) public pure returns (bytes memory) {
        return ResolverProfileRewriterLib.replaceNode(call, node);
    }

    function drop4(bytes calldata v) public pure returns (bytes memory) {
        return v[4:];
    }

    function testFuzz_replaceNode_call(bytes32 node, uint256 coinType) external view {
        (bytes32 x, uint256 c) = abi.decode(
            this.drop4(
                this.replaceNode(
                    abi.encodeCall(IAddressResolver.addr, (keccak256("a"), coinType)),
                    node
                )
            ),
            (bytes32, uint256)
        );
        assertEq(x, node, "node");
        assertEq(c, coinType, "coinType");
    }

    function testFuzz_replaceNode_multicall(bytes32 node, uint8 calls) external view {
        bytes[] memory m = new bytes[](calls);
        for (uint256 i; i < calls; i++) {
            m[i] = abi.encodeCall(IAddressResolver.addr, (keccak256("a"), i));
        }
        m = abi.decode(
            this.drop4(this.replaceNode(abi.encodeCall(IMulticallable.multicall, (m)), node)),
            (bytes[])
        );
        assertEq(m.length, calls, "count");
        for (uint256 i; i < calls; i++) {
            (bytes32 x, uint256 c) = abi.decode(this.drop4(m[i]), (bytes32, uint256));
            assertEq(x, node, "node");
            assertEq(c, i, "coinType");
        }
    }
}
