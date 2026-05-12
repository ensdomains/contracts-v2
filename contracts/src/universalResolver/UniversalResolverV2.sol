// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    AbstractUniversalResolver,
    ERC165
} from "@ens/contracts/universalResolver/AbstractUniversalResolver.sol";
import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";

import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";

import {LibRegistry} from "./libraries/LibRegistry.sol";

/// @notice ENS Universal Resolver that traverses the namechain registry hierarchy to locate
///         resolvers and registries for any DNS-encoded name.
contract UniversalResolverV2 is AbstractUniversalResolver, IContractNamer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 root registry.
    IPermissionedRegistry public immutable ROOT_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootRegistry The root registry.
    /// @param batchGatewayProvider The batch gateway provider.
    constructor(IPermissionedRegistry rootRegistry, IGatewayProvider batchGatewayProvider)
        AbstractUniversalResolver(batchGatewayProvider)
    {
        ROOT_REGISTRY = rootRegistry;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IContractNamer).interfaceId || super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IContractNamer
    function isContractNamer(address namer) external view returns (bool) {
        return ROOT_REGISTRY.isContractNamer(namer);
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
    /// @return The canonical registry or null if not found.
    function findExactRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibRegistry.findExactRegistry(ROOT_REGISTRY, name, 0);
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

    /// @inheritdoc AbstractUniversalResolver
    function findResolver(bytes memory name)
        public
        view
        override
        returns (address resolver, bytes32 node, uint256 offset)
    {
        (, resolver, node, offset) = LibRegistry.findResolver(ROOT_REGISTRY, name, 0);
    }
}
