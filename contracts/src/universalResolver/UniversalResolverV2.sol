// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {
    AbstractUniversalResolver
} from "@ens/contracts/universalResolver/AbstractUniversalResolver.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";

import {IUniversalResolverV2} from "./interfaces/IUniversalResolverV2.sol";
import {LibRegistry} from "./libraries/LibRegistry.sol";

/// @notice Universal Resolver that traverses the namechain registry hierarchy to locate
///         resolvers and registries for any DNS-encoded name.
contract UniversalResolverV2 is
    AbstractUniversalResolver,
    DelegatedContractNamer,
    IUniversalResolverV2
{
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
    /// @param contractNamer Delegated contract namer.
    constructor(
        IPermissionedRegistry rootRegistry,
        IGatewayProvider batchGatewayProvider,
        IContractNamer contractNamer
    )
        AbstractUniversalResolver(batchGatewayProvider)
        DelegatedContractNamer(contractNamer)
    {
        ROOT_REGISTRY = rootRegistry;
    }

    /// @inheritdoc AbstractUniversalResolver
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AbstractUniversalResolver, DelegatedContractNamer)
        returns (bool)
    {
        // note: this is some kind of compiler bug probably due to oz v4/v5
        return
            type(IUniversalResolverV2).interfaceId == interfaceId ||
            AbstractUniversalResolver.supportsInterface(interfaceId) ||
            DelegatedContractNamer.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IUniversalResolverV2
    function isENSv2() external pure returns (bool) {
        return true;
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
