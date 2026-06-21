// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x2b393b33`
interface IPubkeySetter {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Public key was changed.
    /// @param node The namehash of `name`.
    /// @param name The DNS-encoded name.
    /// @param x The x-coordinate of the public key.
    /// @param y The y-coordinate of the public key.
    event PubkeyUpdated(bytes32 indexed node, bytes name, bytes32 x, bytes32 y);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set SECP256k1 public key associated with an ENS node.
    /// @param name The DNS-encoded name.
    /// @param x The x-coordinate of the public key.
    /// @param y The y-coordinate of the public key.
    function setPubkey(bytes calldata name, bytes32 x, bytes32 y) external;
}
