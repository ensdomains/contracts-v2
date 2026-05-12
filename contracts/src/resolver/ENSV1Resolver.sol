// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {RegistryUtils, ENS} from "@ens/contracts/universalResolver/RegistryUtils.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";

import {AbstractMirrorResolver} from "./AbstractMirrorResolver.sol";

/// @notice Resolver that performs resolutions using ENSv1.
contract ENSV1Resolver is AbstractMirrorResolver {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv1 registry used to look up resolvers for names.
    ENS public immutable REGISTRY_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootRegistry The ENSv2 root registry.
    /// @param batchGatewayProvider The batch gateway provider.
    /// @param registryV1 The ENSv1 registry.
    constructor(
        IPermissionedRegistry rootRegistry,
        IGatewayProvider batchGatewayProvider,
        ENS registryV1
    )
        AbstractMirrorResolver(rootRegistry, batchGatewayProvider)
    {
        REGISTRY_V1 = registryV1;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc AbstractMirrorResolver
    function _findResolver(bytes calldata name) internal view override returns (address resolver) {
        (resolver, , ) = RegistryUtils.findResolver(REGISTRY_V1, name, 0);
    }
}
