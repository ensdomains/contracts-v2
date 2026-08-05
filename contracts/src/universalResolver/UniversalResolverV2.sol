// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {
    AbstractUniversalResolver
} from "@ens/contracts/universalResolver/AbstractUniversalResolver.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";

import {IENSIP15} from "./interfaces/IENSIP15.sol";
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

    /// @notice ENSv2 root registry.
    IPermissionedRegistry public immutable ROOT_REGISTRY;

    /// @notice ENSIP-15 normalization implementation.
    IENSIP15 public immutable ENSIP_15;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootRegistry ENSv2 root registry.
    /// @param batchGatewayProvider Shared batch gateway provider.
    /// @param ensip15 ENSIP-15 Normalization implementation.
    /// @param contractNamer Delegated contract namer.
    constructor(
        IPermissionedRegistry rootRegistry,
        IGatewayProvider batchGatewayProvider,
        IENSIP15 ensip15,
        IContractNamer contractNamer
    )
        AbstractUniversalResolver(batchGatewayProvider)
        DelegatedContractNamer(contractNamer)
    {
        ROOT_REGISTRY = rootRegistry;
        ENSIP_15 = ensip15;
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
    function normalize(bytes calldata name) external view returns (bytes memory) {
        return LibRegistry.normalize(name, 0, ENSIP_15);
    }

    /// @inheritdoc AbstractUniversalResolver
    function findResolver(bytes memory name)
        public
        view
        override
        returns (address resolver, bytes32 node, uint256 offset)
    {
        (, resolver, node, offset) = LibRegistry.findResolver(ROOT_REGISTRY, name, 0, ENSIP_15);
    }
}
