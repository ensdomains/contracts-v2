// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {CCIPReader} from "@ens/contracts/ccipRead/CCIPReader.sol";
import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {ICompositeResolver} from "@ens/contracts/resolvers/profiles/ICompositeResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {ResolverCaller} from "@ens/contracts/universalResolver/ResolverCaller.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";

import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";

/// @dev Resolver that mirrors resolution of the same name to a different registry.
abstract contract AbstractMirrorResolver is
    ICompositeResolver,
    IERC7996,
    ResolverCaller,
    DelegatedContractNamer
{
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Shared batch gateway provider.
    IGatewayProvider public immutable BATCH_GATEWAY_PROVIDER;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param batchGatewayProvider The batch gateway provider.
    /// @param contractNamer Delegated contract namer.
    constructor(IGatewayProvider batchGatewayProvider, IContractNamer contractNamer)
        CCIPReader(DEFAULT_UNSAFE_CALL_GAS)
        DelegatedContractNamer(contractNamer)
    {
        BATCH_GATEWAY_PROVIDER = batchGatewayProvider;
    }

    /// @inheritdoc DelegatedContractNamer
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(DelegatedContractNamer)
        returns (bool)
    {
        return
            type(IExtendedResolver).interfaceId == interfaceId ||
            type(ICompositeResolver).interfaceId == interfaceId ||
            type(IERC7996).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IERC7996
    function supportsFeature(bytes4 feature) external pure returns (bool) {
        return ResolverFeatures.RESOLVE_MULTICALL == feature;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IExtendedResolver
    function resolve(bytes calldata name, bytes calldata data) external view returns (bytes memory) {
        callResolver(
            _findResolverRejectingOffchainLookup(name),
            name,
            data,
            false,
            "",
            BATCH_GATEWAY_PROVIDER.gateways()
        );
    }

    /// @inheritdoc ICompositeResolver
    function getResolver(bytes calldata name) external view returns (address, bool) {
        return (_findResolverRejectingOffchainLookup(name), false);
    }

    /// @notice Determine the resolver for `name`.
    /// @param name The DNS-encoded name.
    /// @return The resolver address.
    function findResolver(bytes calldata name) external view virtual returns (address);

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Same as `findResolver()` but prevents `OffchainLookup` revert.
    function _findResolverRejectingOffchainLookup(bytes memory name)
        internal
        view
        returns (address)
    {
        return
            abi.decode(
                callRejectingOffchainLookup(address(this), abi.encodeCall(this.findResolver, (name))),
                (address)
            );
    }
}
