// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IENSIP15} from "./IENSIP15.sol";
import {INormalizedUniversalResolver} from "./INormalizedUniversalResolver.sol";

/// @notice Interface for advanced `UniversalResolver` functionality.
/// @dev Interface selector: `0x53f09390`
interface INormalizedUniversalResolverExtended is INormalizedUniversalResolver {
    /// @notice Performs ENS normalization and forward resolution for the supplied name and data.
    ///         `bytes32 node` is automatically replaced in calldata.
    /// @dev Caller should enable EIP-3668.
    ///      Reverts `NormalizationChangedName`.
    /// @param inputName Human-readable name to resolve, eg. `nick.eth`.
    /// @param data The ABI-encoded resolver calldata.
    /// @param gateways The list of batch gateway URLs to use.
    /// @param ensip15 ENSIP-15 Normalization implementation.
    /// @return result The ABI-encoded response for the calldata.
    /// @return resolver The resolver that was used to resolve the name.
    function resolveWithGatewaysAndENSIP15(
        string calldata inputName,
        bytes calldata data,
        string[] calldata gateways,
        IENSIP15 ensip15
    )
        external
        view
        returns (bytes memory result, address resolver);

    /// @notice Performs ENS reverse resolution for the supplied address and coin type.
    ///         Reverts `PrimaryNameNotNormalized` if the primary name is not normalized.
    /// @dev Caller should enable EIP-3668.
    /// @param lookupAddress The input address.
    /// @param coinType The coin type.
    /// @param gateways The list of batch gateway URLs to use.
    /// @param ensip15 ENSIP-15 Normalization implementation.
    /// @return primary The resolved primary name.
    /// @return resolver The resolver address for primary name.
    /// @return reverseResolver The resolver address for the reverse name.
    function reverseWithGatewaysAndENSIP15(
        bytes calldata lookupAddress,
        uint256 coinType,
        string[] calldata gateways,
        IENSIP15 ensip15
    )
        external
        view
        returns (string memory primary, address resolver, address reverseResolver);
}
