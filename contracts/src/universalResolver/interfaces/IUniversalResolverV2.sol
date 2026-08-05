// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for ENSv2-specific UniversalResolver.
/// @dev Interface selector: `0xe9a24feb`
interface IUniversalResolverV2 {
    /// @notice Normalize a name.
    /// @param name Unnormalized DNS-encoded name.
    /// @return Normalized DNS-encoded name or reverts.
    function normalize(bytes calldata name) external view returns (bytes memory);
}
