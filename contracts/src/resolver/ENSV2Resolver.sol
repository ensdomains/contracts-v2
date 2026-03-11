// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";

import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {LibRegistry} from "../universalResolver/libraries/LibRegistry.sol";

import {AbstractMirrorResolver} from "./AbstractMirrorResolver.sol";

/// @notice Resolver that performs resolutions using ENSv2.
contract ENSV2Resolver is AbstractMirrorResolver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev The ENSv2 root registry used to traverse the registry hierarchy and locate resolvers.
    IRegistry public immutable ROOT_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        IRegistry rootRegistry,
        IGatewayProvider batchGatewayProvider
    ) AbstractMirrorResolver(batchGatewayProvider) {
        ROOT_REGISTRY = rootRegistry;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc AbstractMirrorResolver
    function _findResolver(bytes calldata name) internal view override returns (address resolver) {
        (, resolver, , ) = LibRegistry.findResolver(ROOT_REGISTRY, name, 0);
    }
}
