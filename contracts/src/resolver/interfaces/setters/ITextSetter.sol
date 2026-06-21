// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0xc7279f88`
interface ITextSetter {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Text was changed.
    /// @param node The namehash of `name`.
    /// @param name The DNS-encoded name.
    /// @param keyHash The hash of `key`.
    /// @param key The text key.
    /// @param value The text value.
    event TextUpdated(
        bytes32 indexed node,
        bytes name,
        string indexed keyHash,
        string key,
        string value
    );

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set text for `key`.
    /// @param name The DNS-encoded name.
    /// @param key The text key.
    /// @param value The text value.
    function setText(bytes calldata name, string calldata key, string calldata value) external;
}
