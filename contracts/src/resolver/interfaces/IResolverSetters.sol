// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x9f7447c1`
interface IResolverSetters {
    /// @notice Set address for `coinType`.
    /// @param name The DNS-encoded name.
    /// @param coinType The coin type.
    /// @param addressBytes The encoded address.
    function setAddress(
        bytes calldata name,
        uint256 coinType,
        bytes calldata addressBytes
    ) external;

    /// @notice Set data for `key`.
    /// @param name The DNS-encoded name.
    /// @param key The data key.
    /// @param data The data.
    function setData(bytes calldata name, string calldata key, bytes calldata data) external;

    /// @notice Set text for `key`.
    /// @param name The DNS-encoded name.
    /// @param key The text key.
    /// @param value The text value.
    function setText(bytes calldata name, string calldata key, string calldata value) external;

    /// @notice Set contenthash.
    /// @param name The DNS-encoded name.
    /// @param contentHash The content hash.
    function setContentHash(bytes calldata name, bytes calldata contentHash) external;

    /// @notice Set ABI data for `contentType`.
    /// @param name The DNS-encoded name.
    /// @param contentType The content type bit of the ABI encoding.
    /// @param data The encoded ABI data.
    function setABI(bytes calldata name, uint256 contentType, bytes calldata data) external;

    /// @notice Set primary name.
    /// @param name The DNS-encoded name.
    /// @param primaryName The name.
    function setName(bytes calldata name, string calldata primaryName) external;

    /// @notice Set implementer for `interfaceId`.
    /// @param name The DNS-encoded name.
    /// @param interfaceId The EIP-165 interface ID.
    /// @param implementer The address of the contract that implements this interface.
    function setInterface(bytes calldata name, bytes4 interfaceId, address implementer) external;

    /// @notice Set SECP256k1 public key associated with an ENS node.
    /// @param name The DNS-encoded name.
    /// @param x The x coordinate of the public key.
    /// @param y The y coordinate of the public key.
    function setPubkey(bytes calldata name, bytes32 x, bytes32 y) external;
}
