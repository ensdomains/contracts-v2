// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";

import {LibRegistry} from "./libraries/LibRegistry.sol";

/// @notice Collection of non-essential ENS functions.
contract UniversalHelper is DelegatedContractNamer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice ENSv2 root registry.
    IPermissionedRegistry public immutable ROOT_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootRegistry The root registry.
    /// @param contractNamer Delegated contract namer.
    constructor(IPermissionedRegistry rootRegistry, IContractNamer contractNamer)
        DelegatedContractNamer(contractNamer)
    {
        ROOT_REGISTRY = rootRegistry;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Find the owner for `name`.
    /// @param name The DNS-encoded name.
    /// @return The owner address or null if unowned or not found.
    function findOwner(bytes calldata name) external view returns (address) {
        return LibRegistry.findOwner(ROOT_REGISTRY, name, 0);
    }

    /// @notice Construct the canonical name for `registry`.
    /// @param registry The registry to name.
    /// @return The DNS-encoded name or empty if not canonical.
    function findCanonicalName(IRegistry registry) external view returns (bytes memory) {
        return LibRegistry.findCanonicalName(ROOT_REGISTRY, registry);
    }

    /// @notice Find the canonical registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The canonical registry or null if not canonical.
    function findCanonicalRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibRegistry.findCanonicalRegistry(ROOT_REGISTRY, name);
    }

    /// @notice Find the exact registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The registry or null if not found.
    function findExactRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibRegistry.findExactRegistry(ROOT_REGISTRY, name, 0);
    }

    /// @notice Find the parent registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The parent registry or null if not found.
    function findParentRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibRegistry.findParentRegistry(ROOT_REGISTRY, name, 0);
    }

    /// @notice Find all registries in the ancestry of `name`.
    /// * `findRegistries("") = [<root>]`
    /// * `findRegistries("eth") = [<eth>, <root>]`
    /// * `findRegistries("nick.eth") = [<nick>, <eth>, <root>]`
    /// * `findRegistries("sub.nick.eth") = [null, <nick>, <eth>, <root>]`
    ///
    /// @param name The DNS-encoded name.
    /// @return Array of registries in label-order.
    function findRegistries(bytes calldata name) external view returns (IRegistry[] memory) {
        return LibRegistry.findRegistries(ROOT_REGISTRY, name, 0);
    }
}
