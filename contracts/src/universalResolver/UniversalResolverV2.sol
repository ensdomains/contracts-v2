// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    AbstractUniversalResolver,
    IGatewayProvider
} from "@ens/contracts/universalResolver/AbstractUniversalResolver.sol";

import {LibRegistry, IRegistry} from "./libraries/LibRegistry.sol";

contract UniversalResolverV2 is AbstractUniversalResolver {
    IRegistry public immutable ROOT_REGISTRY;

    constructor(
        IRegistry root,
        IGatewayProvider batchGatewayProvider
    ) AbstractUniversalResolver(batchGatewayProvider) {
        ROOT_REGISTRY = root;
    }

    /// @notice Check if `name` is canonical.
    ///
    /// @param name The DNS-encoded name.
    ///
    /// @return True if `name` is canonical.
    function isCanonical(bytes memory name) external view returns (bool) {
        return address(LibRegistry.findCanonicalRegistry(ROOT_REGISTRY, name, 0)) != address(0);
    }

    /// @notice Find all registries in the ancestry of `name`.
    /// * `findRegistries("") = [<root>]`
    /// * `findRegistries("eth") = [<eth>, <root>]`
    /// * `findRegistries("nick.eth") = [<nick>, <eth>, <root>]`
    /// * `findRegistries("sub.nick.eth") = [null, <nick>, <eth>, <root>]`
    ///
    /// @param name The DNS-encoded name.
    ///
    /// @return Array of registries in label-order.
    function findRegistries(bytes calldata name) external view returns (IRegistry[] memory) {
        return LibRegistry.findRegistries(ROOT_REGISTRY, name, 0);
    }

    /// @inheritdoc AbstractUniversalResolver
    function findResolver(
        bytes memory name
    ) public view override returns (address resolver, bytes32 node, uint256 offset) {
        (, resolver, node, offset) = LibRegistry.findResolver(ROOT_REGISTRY, name, 0);
    }
}
