// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {RegistryUtils, ENS} from "@ens/contracts/universalResolver/RegistryUtils.sol";

import {AbstractMirrorResolver} from "./AbstractMirrorResolver.sol";

/// @notice Resolver that performs resolutions using ENSv1.
contract ENSV1Resolver is AbstractMirrorResolver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv1 registry used to look up resolvers for names.
    ENS public immutable REGISTRY_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the ENSV1Resolver with the ENSv1 registry and batch gateway provider.
    /// @param registryV1 The ENSv1 registry.
    /// @param batchGatewayProvider The batch gateway provider.
    constructor(ENS registryV1, IGatewayProvider batchGatewayProvider) AbstractMirrorResolver(batchGatewayProvider) {
        REGISTRY_V1 = registryV1;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc AbstractMirrorResolver
    function _findResolver(bytes calldata name) internal view override returns (address resolver) {
        (resolver,,) = RegistryUtils.findResolver(REGISTRY_V1, name, 0);
    }
}
