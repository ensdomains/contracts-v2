// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Utilities for computing labelhash-based token IDs and applying version suffixes.
library LibLabel {
    /// @notice Compute `labelhash(label)`.
    function id(string memory label) internal pure returns (uint256) {
        return uint256(keccak256(bytes(label)));
    }

    /// @notice Replace the lower 32-bits of `anyId` with `versionId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @param versionId The version ID.
    /// @return The versioned ID.
    function withVersion(uint256 anyId, uint32 versionId) internal pure returns (uint256) {
        return anyId ^ uint32(anyId) ^ versionId;
    }

    /// @notice Return the lower 32-bits of `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The version ID.
    function versionOf(uint256 anyId) internal pure returns (uint32) {
        return uint32(anyId);
    }
}
