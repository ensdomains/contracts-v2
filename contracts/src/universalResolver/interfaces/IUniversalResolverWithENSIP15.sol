// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IENSIP15} from "./IENSIP15.sol";

/// @notice Interface for ENSv2-specific `UniversalResolver`.
/// @dev Interface selector: `0x3278ebb9`
interface IUniversalResolverWithENSIP15 {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Primary name was not normalized.
    /// @dev Error selector: `0x28c6aa0c`
    error PrimaryNameNotNormalized(string primary);

    /// @notice Input name was not normalized; resolved normalized name instead.
    /// @dev Error selector: `0x2dba1353`
    error NormalizationChangedName(bytes normalizedName, bytes result, address resolver);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Performs ENS forward resolution for the supplied name and data.
    ///         Caller should enable EIP-3668.
    ///         Reverts `NormalizationChangedName`.
    /// @param ensName Literal name to resolve, eg. `nick.eth`.
    /// @param data The ABI-encoded resolver calldata.
    /// @param ensip15 ENSIP-15 Normalization implementation.
    /// @return result The ABI-encoded response for the calldata.
    /// @return resolver The resolver that was used to resolve the name.
    function resolve(string calldata ensName, bytes calldata data, IENSIP15 ensip15)
        external
        view
        returns (bytes memory result, address resolver);

    /// @notice Performs ENS reverse resolution for the supplied address and coin type.
    ///         Caller should enable EIP-3668.
    ///         Reverts `PrimaryNameNotNormalized`.
    /// @param lookupAddress The input address.
    /// @param coinType The coin type.
    /// @param ensip15 ENSIP-15 Normalization implementation.
    /// @return primary The resolved normalized primary name.
    /// @return resolver The resolver address for primary name.
    /// @return reverseResolver The resolver address for the reverse name.
    function reverse(bytes calldata lookupAddress, uint256 coinType, IENSIP15 ensip15)
        external
        view
        returns (string memory primary, address resolver, address reverseResolver);

    /// @notice Normalize a name according to ENSIP-15.
    /// @param ensName Literal name to normalize, eg. `nick.eth`.
    /// @param ensip15 ENSIP-15 Normalization implementation.
    /// @return wasNormalized `true` if normalized.
    /// @return name Normalized DNS-encoded name, eg. `\x04nick\x03eth\x00` or null if not normalizable.
    function normalize(string calldata ensName, IENSIP15 ensip15)
        external
        view
        returns (bool wasNormalized, bytes memory name);

    /// @notice Return `true` if ENSv2 otherwise ENSv1.
    function isENSv2() external view returns (bool);
}
