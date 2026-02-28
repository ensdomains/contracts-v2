// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {CCIPReader} from "@ens/contracts/ccipRead/CCIPReader.sol";
import {IGatewayProvider} from "@ens/contracts/ccipRead/IGatewayProvider.sol";
import {ICompositeResolver} from "@ens/contracts/resolvers/profiles/ICompositeResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {ResolverCaller} from "@ens/contracts/universalResolver/ResolverCaller.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

/// @notice Resolver that mirrors resolution of the same name to a different registry.
abstract contract AbstractMirrorResolver is ICompositeResolver, IERC7996, ResolverCaller, ERC165 {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Shared batch gateway provider.
    IGatewayProvider public immutable BATCH_GATEWAY_PROVIDER;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(IGatewayProvider batchGatewayProvider) CCIPReader(DEFAULT_UNSAFE_CALL_GAS) {
        BATCH_GATEWAY_PROVIDER = batchGatewayProvider;
    }

    /// @inheritdoc ERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165) returns (bool) {
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
    function resolve(
        bytes calldata name,
        bytes calldata data
    ) external view returns (bytes memory) {
        callResolver(_findResolver(name), name, data, false, "", BATCH_GATEWAY_PROVIDER.gateways());
    }

    /// @inheritdoc ICompositeResolver
    function getResolver(bytes calldata name) external view returns (address, bool) {
        return (_findResolver(name), false);
    }

    /// @inheritdoc ICompositeResolver
    function requiresOffchain(bytes calldata) external pure returns (bool) {
        return false;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Determine the resolver for `name`.
    function _findResolver(bytes calldata name) internal view virtual returns (address);
}
