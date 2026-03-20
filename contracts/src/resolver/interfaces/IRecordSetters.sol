// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x8fbfdcd1`
interface IRecordSetters {
    /// @notice Set address for `coinType`.
    /// @param coinType The coin type.
    /// @param addressBytes The encoded address.
    function setAddress(uint256 coinType, bytes calldata addressBytes) external;

    /// @notice Set data for `key`.
    /// @param key The data key.
    /// @param data The data.
    function setData(string calldata key, bytes calldata data) external;

    /// @notice Set text for `key`.
    /// @param key The text key.
    /// @param value The text value.
    function setText(string calldata key, string calldata value) external;

    /// @notice Set the contenthash.
    /// @param contentHash The content hash.
    function setContentHash(bytes calldata contentHash) external;

    /// @notice Set ABI data for `contentType`.
    /// @param contentType The content type bit of the ABI encoding.
    /// @param data The encoded ABI data.
    function setABI(uint256 contentType, bytes calldata data) external;

    /// @notice Set the primary name.
    /// @param name The primary name.
    function setName(string calldata name) external;

    /// @notice Set implementer for `interfaceId`.
    /// @param interfaceId The EIP-165 interface ID.
    /// @param implementer The address of the contract that implements this interface.
    function setInterface(bytes4 interfaceId, address implementer) external;

    /// @notice Set the SECP256k1 public key associated with an ENS node.
    /// @param x The x coordinate of the public key.
    /// @param y The y coordinate of the public key.
    function setPubkey(bytes32 x, bytes32 y) external;

    /// @notice Clear the record.
    function clear() external;
}
