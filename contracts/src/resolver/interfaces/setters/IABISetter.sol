// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0xd26f550e`
interface IABISetter {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice ABI was changed.
    /// @param node The namehash of `name`.
    /// @param name The DNS-encoded name.
    /// @param contentType The ABI content type.
    event ABIUpdated(bytes32 indexed node, bytes name, uint256 indexed contentType);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The content type must be a single bit.
    /// @dev Error selector: `0x5742bb26`
    error InvalidContentType(uint256 contentType);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set ABI for `contentType`.
    /// @param name The DNS-encoded name.
    /// @param contentType The ABI content type.
    /// @param data The ABI data.
    function setABI(bytes calldata name, uint256 contentType, bytes calldata data) external;
}
