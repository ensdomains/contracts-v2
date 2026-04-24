// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Rewrites the `bytes32 node` parameter in resolver calldata. Resolver functions follow
/// the convention `func(bytes32 node, ...)`, with the node at calldata offset 4. This library
/// replaces that node in a memory copy of the calldata, recursively handling `multicall(bytes[])`
/// (selector `0xac9650d8`) to rewrite the node in every nested call at arbitrary depth.
///
/// Used by `PermissionedResolver` when resolving aliased names: after determining the alias target,
/// the original calldata must be updated with the new node before forwarding to the actual
/// resolver logic.
///
library ResolverProfileRewriterLib {
    /// @dev Replace the node in the calldata with a new node.
    ///      Supports `multicall()` to arbitrary depth.
    /// @param call The calldata for a resolver.
    /// @param newNode The replacement node.
    /// @return copy A copy of the calldata with node replaced.
    function replaceNode(bytes calldata call, bytes32 newNode)
        internal
        pure
        returns (bytes memory copy)
    {
        copy = call; // make a copy
        assembly {
            function replace(ptr, node) {
                switch shr(224, mload(add(ptr, 32))) // call selector
                case 0xac9650d8 {
                    // multicall(bytes[])
                    let off := add(ptr, 36)
                    off := add(off, mload(off))
                    let size := shl(5, mload(off))
                    // prettier-ignore
                    for { } size { size := sub(size, 32) } {
                        replace(add(add(off, 32), mload(add(off, size))), node)
                    }
                }
                default {
                    mstore(add(ptr, 36), node) // replace node
                }
            }
            replace(copy, newNode)
        }
    }
}
