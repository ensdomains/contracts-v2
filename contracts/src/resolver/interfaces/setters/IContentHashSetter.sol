// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x6e057a4e`
interface IContentHashSetter {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Primary name was changed.
    /// @param node The namehash of `name`.
    /// @param name The DNS-encoded name.
    /// @param contentHash The content hahs.
    event ContentHashUpdated(bytes32 indexed node, bytes name, bytes contentHash);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set contenthash.
    /// @param name The DNS-encoded name.
    /// @param contentHash The content hash.
    function setContentHash(bytes calldata name, bytes calldata contentHash) external;
}
