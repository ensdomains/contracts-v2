// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {
    AbstractUniversalResolver
} from "@ens/contracts/universalResolver/AbstractUniversalResolver.sol";

import {IRegistry} from "../registry/interfaces/IRegistry.sol";

import {IUniversalResolverV2} from "./interfaces/IUniversalResolverV2.sol";
import {LibRegistry} from "./libraries/LibRegistry.sol";

/// @notice ENS Universal Resolver that traverses the namechain registry hierarchy to locate
///         resolvers and registries for any DNS-encoded name.
contract UniversalResolverV2 is AbstractUniversalResolver, IUniversalResolverV2 {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 root registry.
    IRegistry public immutable ROOT_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the UniversalResolverV2 with the root registry and batch gateway provider.
    /// @param root The root registry.
    /// @param batchGatewayProvider The batch gateway provider.
    constructor(
        IRegistry root,
        IGatewayProvider batchGatewayProvider
    ) AbstractUniversalResolver(batchGatewayProvider) {
        ROOT_REGISTRY = root;
    }

    /// @inheritdoc AbstractUniversalResolver
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(AbstractUniversalResolver) returns (bool) {
        return
            type(IUniversalResolverV2).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IUniversalResolverV2
    function findCanonicalName(IRegistry registry) external view returns (bytes memory) {
        return LibRegistry.findCanonicalName(ROOT_REGISTRY, registry);
    }

    /// @inheritdoc IUniversalResolverV2
    function findCanonicalRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibRegistry.findCanonicalRegistry(ROOT_REGISTRY, name);
    }

    /// @inheritdoc IUniversalResolverV2
    function findExactRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibRegistry.findExactRegistry(ROOT_REGISTRY, name, 0);
    }

    /// @inheritdoc IUniversalResolverV2
    function findParentRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibRegistry.findParentRegistry(ROOT_REGISTRY, name, 0);
    }

    /// @inheritdoc IUniversalResolverV2
    function findRegistries(bytes calldata name) external view returns (IRegistry[] memory) {
        return LibRegistry.findRegistries(ROOT_REGISTRY, name, 0);
    }

    /// @inheritdoc AbstractUniversalResolver
    function findResolver(
        bytes memory name
    ) public view override returns (address resolver, bytes32 node, uint256 offset) {
        (, resolver, node, offset) = LibRegistry.findResolver(ROOT_REGISTRY, name, 0);
    }
}
