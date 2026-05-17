// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "../../registry/interfaces/IRegistry.sol";

/// @notice Interface for ENSv2-specific UniversalResolver helper functions.
/// @dev Interface selector: `0x6e37653d`
interface IUniversalResolverV2 {
    /// @notice Construct the canonical name for `registry`.
    /// @param registry The registry to name.
    /// @return The DNS-encoded name or empty if not canonical.
    function findCanonicalName(IRegistry registry) external view returns (bytes memory);

    /// @notice Find the canonical registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The canonical registry or null if not canonical.
    function findCanonicalRegistry(bytes calldata name) external view returns (IRegistry);

    /// @notice Find the exact registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The registry or null if not found.
    function findExactRegistry(bytes calldata name) external view returns (IRegistry);

    /// @notice Find the parent registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The parent registry or null if not found.
    function findParentRegistry(bytes calldata name) external view returns (IRegistry);

    /// @notice Find all registries in the ancestry of `name`.
    /// * `findRegistries("") = [<root>]`
    /// * `findRegistries("eth") = [<eth>, <root>]`
    /// * `findRegistries("nick.eth") = [<nick>, <eth>, <root>]`
    /// * `findRegistries("sub.nick.eth") = [null, <nick>, <eth>, <root>]`
    ///
    /// @param name The DNS-encoded name.
    /// @return Array of registries in label-order.
    function findRegistries(bytes calldata name) external view returns (IRegistry[] memory);
}
