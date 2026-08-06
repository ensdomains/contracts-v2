// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for ENSv2-specific UniversalResolver.
/// @dev Interface selector: `0xe9a24feb`
interface IUniversalResolverV2 {
    /// @notice Normalize a name according to ENSIP-15.
    /// @param name The DNS-encoded name to normalize.
    /// @return Normalized The normalized DNS-encoded name.
    function normalize(bytes calldata name) external view returns (bytes memory);
}
