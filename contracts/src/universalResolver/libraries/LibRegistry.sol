// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {BytesUtils} from "@ens/contracts/utils/BytesUtils.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {IRegistry} from "../../registry/interfaces/IRegistry.sol";

library LibRegistry {
    /// @dev Find the resolver address for `name[offset:]`.
    ///
    /// @param rootRegistry The root ENS registry.
    /// @param name The DNS-encoded name to search.
    /// @param offset The offset into `name` to begin the search.
    ///
    /// @return exactRegistry The exact registry or null if not exact.
    /// @return resolver The resolver or null if not found.
    /// @return node The namehash of `name[offset:]`.
    /// @return resolverOffset The offset into `name` corresponding to `resolver`.
    function findResolver(
        IRegistry rootRegistry,
        bytes memory name,
        uint256 offset
    )
        internal
        view
        returns (IRegistry exactRegistry, address resolver, bytes32 node, uint256 resolverOffset)
    {
        // supply <root> if end of name
        (bytes32 labelHash, uint256 next) = NameCoder.readLabel(name, offset);
        if (labelHash == bytes32(0)) {
            return (rootRegistry, address(0), bytes32(0), offset);
        }
        // lookup parent name
        (exactRegistry, resolver, node, resolverOffset) = findResolver(rootRegistry, name, next);
        // if there was a parent registry...
        if (address(exactRegistry) != address(0)) {
            (string memory label, ) = NameCoder.extractLabel(name, offset);
            // remember the resolver (if it exists)
            address res = exactRegistry.getResolver(label);
            if (res != address(0)) {
                resolver = res;
                resolverOffset = offset;
            }
            exactRegistry = exactRegistry.getSubregistry(label);
        }
        node = NameCoder.namehash(node, labelHash); // update namehash
    }

    /// @notice Find (registry, resolver) for `name[offset:]` starting from
    ///         (parentRegistry, parentRegistry) for `name[:parentOffset]`.
    ///
    /// @param name The DNS-encoded name to search.
    /// @param offset The offset into `name` to begin the search.
    /// @param parentOffset The offset into `name` to use parent values.
    /// @param parentRegistry The registry at `name[length:]`.
    /// @param parentResolver The resolver at `name[length:]`.
    ///
    /// @return registry The exact registry or null if not exact.
    /// @return resolver The resolver or null if not found.
    function findResolverFromParent(
        bytes memory name,
        uint256 offset,
        uint256 parentOffset,
        IRegistry parentRegistry,
        address parentResolver
    ) internal view returns (IRegistry registry, address resolver) {
        if (offset > parentOffset) {
            revert NameCoder.DNSDecodingFailed(name);
        } else if (offset == parentOffset) {
            return (parentRegistry, parentResolver);
        } else {
            string memory label;
            (label, offset) = NameCoder.extractLabel(name, offset);
            (registry, resolver) = findResolverFromParent(
                name,
                offset,
                parentOffset,
                parentRegistry,
                parentResolver
            );
            if (address(registry) != address(0)) {
                address res = registry.getResolver(label);
                if (res != address(0)) {
                    resolver = res;
                }
                registry = registry.getSubregistry(label);
            }
        }
    }

    /// @notice Find the canonical registry for `name`.
    ///
    /// @dev `name` is canonical if it's ancestors are canonical and share parential suffixes:
    /// eg.        Canonical    not-Canonical     not-Canonical
    ///            =========    =============     =============
    ///     abc.sub.test.eth          abc.eth      a.b.test.eth
    ///         sub.test.eth            > xyz <      b.test.eth
    ///             test.eth            <root>       > nick.eth <
    ///                  eth                                eth
    ///                <root>                             <root>
    ///
    /// @param rootRegistry The root ENS registry.
    /// @param name The DNS-encoded name to verify.
    /// @param offset The offset into `name` to start verification.
    ///
    /// @return registry The canonical registry or null if not canonical.
    function findCanonicalRegistry(
        IRegistry rootRegistry,
        bytes memory name,
        uint256 offset
    ) internal view returns (IRegistry registry) {
        if (offset > name.length) {
            return IRegistry(address(0));
        }
        (string memory label, uint256 next) = NameCoder.extractLabel(name, offset);
        if (bytes(label).length == 0) {
            return rootRegistry;
        }
        IRegistry parent = findCanonicalRegistry(rootRegistry, name, next);
        if (address(parent) != address(0)) {
            IRegistry child = parent.getSubregistry(label);
            if (address(child) != address(0)) {
                bytes memory childName = child.getCanonicalName();
                if (
                    name.length >= childName.length &&
                    //NameCoder.namehash(childName, 0) == NameCoder.namehash(name, offset)
                    keccak256(childName) == BytesUtils.keccak(name, offset, name.length - offset) // must have same suffix
                ) {
                    return child;
                }
            }
        }
    }

    /// @dev Find the exact registry for `name[offset:]`.
    ///
    /// @param rootRegistry The root ENS registry.
    /// @param name The DNS-encoded name to search.
    ///
    /// @return exactRegistry The exact registry or null if not found.
    function findExactRegistry(
        IRegistry rootRegistry,
        bytes memory name,
        uint256 offset
    ) internal view returns (IRegistry exactRegistry) {
        (bytes32 labelHash, uint256 next) = NameCoder.readLabel(name, offset);
        if (labelHash == bytes32(0)) {
            return rootRegistry;
        }
        IRegistry parent = findExactRegistry(rootRegistry, name, next);
        if (address(parent) != address(0)) {
            (string memory label, ) = NameCoder.extractLabel(name, offset);
            exactRegistry = parent.getSubregistry(label);
        }
    }

    /// @dev Find the parent registry for `name[offset:]`.
    ///
    /// @param rootRegistry The root ENS registry.
    /// @param name The DNS-encoded name to search.
    ///
    /// @return parentRegistry The parent registry or null if not found.
    function findParentRegistry(
        IRegistry rootRegistry,
        bytes memory name,
        uint256 offset
    ) internal view returns (IRegistry parentRegistry) {
        (bytes32 labelHash, uint256 next) = NameCoder.readLabel(name, offset);
        if (labelHash != bytes32(0)) {
            parentRegistry = findExactRegistry(rootRegistry, name, next);
        }
    }

    /// @notice Find all registries in the ancestry of `name`.
    ///
    /// @param rootRegistry The root ENS registry.
    /// @param name The DNS-encoded name.
    /// @param offset The offset into `name` to begin the search.
    ///
    /// @return registries Array of registries in label-order.
    function findRegistries(
        IRegistry rootRegistry,
        bytes memory name,
        uint256 offset
    ) internal view returns (IRegistry[] memory registries) {
        registries = new IRegistry[](1 + NameCoder.countLabels(name, offset));
        registries[registries.length - 1] = rootRegistry;
        _findRegistries(name, offset, registries, 0);
    }

    /// @dev Recursive function for building ancestory.
    function _findRegistries(
        bytes memory name,
        uint256 offset,
        IRegistry[] memory registries,
        uint256 index
    ) private view returns (IRegistry registry) {
        (string memory label, uint256 nextOffset) = NameCoder.extractLabel(name, offset);
        if (bytes(label).length == 0) {
            return registries[registries.length - 1];
        }
        registry = _findRegistries(name, nextOffset, registries, index + 1);
        if (address(registry) != address(0)) {
            registry = registry.getSubregistry(label);
            registries[index] = registry;
        }
    }
}
