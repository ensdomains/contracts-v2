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
    function replaceNode(
        bytes calldata call,
        bytes32 newNode
    ) internal pure returns (bytes memory copy) {
        // 0xac9650d8                                                       // selector
        // 0000000000000000000000000000000000000000000000000000000000000020 // jump
        // 0000000000000000000000000000000000000000000000000000000000000002 // .length @ jump
        // 0000000000000000000000000000000000000000000000000000000000000040 // jump[0]
        // 00000000000000000000000000000000000000000000000000000000000000a0 // jump[1]
        // 0000000000000000000000000000000000000000000000000000000000000024 // [0].length @ jump[0]
        // ...
        // 0000000000000000000000000000000000000000000000000000000000000024 // [1].length @ jump[1]
        // ...
        copy = call; // make a copy
        assembly {
            function replace(ptr, bound, node) {
                ptr := add(ptr, 36) // skip length + selector
                switch shr(224, mload(sub(ptr, 4))) // read selector
                case 0xac9650d8 {
                    // multicall(bytes[])
                    ptr := add(ptr, mload(ptr)) // follow jump
                    let size := shl(5, mload(ptr)) // read word count as size
                    // prettier-ignore
                    for { } size { size := sub(size, 32) } { // backwards
                        let p := mload(add(ptr, size)) // jump[i]
                        p := add(add(ptr, 32), p) // local ptr
                        let b := add(p, mload(p)) // local bound w/room for 1 word
                        if lt(bound, b) {
                            b := bound // global bound is smaller
                        }
                        replace(p, b, node)
                    }
                }
                default {
                    // only bound checks on write
                    if lt(bound, ptr) {
                        // mstore(0, 0x4e487b71) // error Panic(uint256)
                        // mstore(32, 0x32) // code
                        // revert(28, 36) // 32-4, 4+32
                        leave
                    }
                    mstore(ptr, node) // replace node
                }
            }
            replace(copy, add(copy, mload(copy)), newNode) // bound w/room for 1 word
        }
    }
}
