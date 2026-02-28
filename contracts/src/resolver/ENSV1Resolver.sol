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

    ENS public immutable REGISTRY_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        ENS registryV1,
        IGatewayProvider batchGatewayProvider
    ) AbstractMirrorResolver(batchGatewayProvider) {
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
