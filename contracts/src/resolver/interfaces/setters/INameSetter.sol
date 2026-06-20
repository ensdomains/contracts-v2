// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x0ce0112a`
interface INameSetter {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Primary name was changed.
    /// @param node The namehash of `name`.
    /// @param name The DNS-encoded name.
    /// @param primaryName The primary name.
    event NameUpdated(bytes32 indexed node, bytes name, string primaryName);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set primary name.
    /// @param name The DNS-encoded name.
    /// @param primaryName The primary name.
    function setName(bytes calldata name, string calldata primaryName) external;
}
