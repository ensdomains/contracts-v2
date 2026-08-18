// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {ENS} from "@ens/contracts/registry/ENS.sol";
import {ReverseClaimer} from "@ens/contracts/reverseRegistrar/ReverseClaimer.sol";
import {RegistryUtils} from "@ens/contracts/universalResolver/RegistryUtils.sol";

import {AbstractUniversalResolverWithENSIP15} from "./AbstractUniversalResolverWithENSIP15.sol";

/// @notice Universal Resolver that traverses the namechain registry hierarchy to locate
///         resolvers and registries for any DNS-encoded name.
contract UniversalResolverV1 is AbstractUniversalResolverWithENSIP15, ReverseClaimer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice ENSv1 global registry.
    ENS public immutable REGISTRY_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param namer The primary name owner.
    /// @param ens ENSv1 global registry.
    /// @param _batchGatewayProvider Shared batch gateway provider.
    constructor(address namer, ENS ens, IGatewayProvider _batchGatewayProvider)
        AbstractUniversalResolverWithENSIP15(_batchGatewayProvider)
        ReverseClaimer(ens, namer)
    {
        REGISTRY_V1 = ens;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Same as `REGISTRY_V1()`.
    function registry() external view returns (ENS) {
        return REGISTRY_V1;
    }

    /// @inheritdoc AbstractUniversalResolverWithENSIP15
    function findResolver(bytes memory name)
        public
        view
        override
        returns (address, bytes32, uint256)
    {
        // https://docs.ens.domains/ensip/10       
        return RegistryUtils.findResolver(REGISTRY_V1, name, 0);
    }

    /// @inheritdoc AbstractUniversalResolverWithENSIP15
    function isENSv2() public pure override returns (bool) {
        return false;
    }
}
