// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {CCIPBatcher} from "@ens/contracts/ccipRead/CCIPBatcher.sol";
import {CCIPReader} from "@ens/contracts/ccipRead/CCIPReader.sol";
import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {ICompositeResolver} from "@ens/contracts/resolvers/profiles/ICompositeResolver.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";

import {LibResolution} from "./libraries/LibResolution.sol";

/// @notice Helper contract for following `ICompositeResolver` chains. 
contract CompositeHelper is DelegatedContractNamer, CCIPBatcher {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    struct ResolverInfo {
        address resolver;
        bool offchain;
    }

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 root registry.
    IPermissionedRegistry public immutable ROOT_REGISTRY;

    /// @notice Shared batch gateway provider.
    IGatewayProvider public immutable BATCH_GATEWAY_PROVIDER;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `ICompositeResolver.getResolver()` failed.
    /// @dev Error selector: `0xafdf3039`
    error UnknownResolver(ResolverInfo[] resolvers, bytes error);

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
        CCIPReader(DEFAULT_UNSAFE_CALL_GAS)
        DelegatedContractNamer(contractNamer)
    {
        ROOT_REGISTRY = rootRegistry;
        BATCH_GATEWAY_PROVIDER = batchGatewayProvider;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Find all resolvers in an `ICompositeResolver` chain.
    /// @param name DNS-encoded name to lookup.
    /// @return Array of resolvers.
    function getResolvers(bytes calldata name) external view returns (ResolverInfo[] memory) {
        (, address resolver, , ) = LibResolution.findResolver(ROOT_REGISTRY, name, 0);
        return _getResolvers(resolver, false, name, new ResolverInfo[](0));
    }

    /// @notice CCIP-Read callback for `_getResolvers()`.
    // solhint-disable-next-line
    function getResolversCallback(bytes calldata response, bytes calldata extraData)
        external
        view
        returns (ResolverInfo[] memory)
    {
        Lookup[] memory lookups = abi.decode(response, (Batch)).lookups;
        (bytes memory name, ResolverInfo[] memory resolvers) =
            abi.decode(extraData, (bytes, ResolverInfo[]));
        Lookup memory lu = lookups[0];
        if ((lu.flags & FLAGS_ANY_ERROR) != 0) {
            revert UnknownResolver(resolvers, lu.data);
        }
        (address resolver, bool offchain) = abi.decode(lu.data, (address, bool));
        return _getResolvers(resolver, offchain, name, resolvers);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Find the next resolver in an `ICompositeResolver` chain.
    function _getResolvers(
        address resolver,
        bool offchain,
        bytes memory name,
        ResolverInfo[] memory src
    )
        internal
        view
        returns (ResolverInfo[] memory dst)
    {
        uint256 n = src.length;
        dst = new ResolverInfo[](n + 1);
        for (uint256 i; i < n; ++i) {
            dst[i] = src[i];
        }
        dst[n] = ResolverInfo(resolver, offchain);
        if (!ERC165Checker.supportsInterface(resolver, type(ICompositeResolver).interfaceId)) {
            return dst;
        }
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(ICompositeResolver.getResolver, (name));
        ccipRead(
            address(this),
            abi.encodeCall(
                this.ccipBatch,
                createBatch(resolver, calls, BATCH_GATEWAY_PROVIDER.gateways())
            ),
            this.getResolversCallback.selector,
            IDENTITY_FUNCTION,
            abi.encode(name, dst)
        );
    }
}
