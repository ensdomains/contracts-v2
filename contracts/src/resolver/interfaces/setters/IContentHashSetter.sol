// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x6e057a4e`
interface IContentHashSetter {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Content hash was changed.
    /// @param recordId The record ID.
    /// @param contentHash The content hash.
    event ContentHashUpdated(uint256 indexed recordId, bytes contentHash);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set content hash.
    /// @param name The DNS-encoded name.
    /// @param contentHash The content hash.
    function setContentHash(bytes calldata name, bytes calldata contentHash) external;
}
