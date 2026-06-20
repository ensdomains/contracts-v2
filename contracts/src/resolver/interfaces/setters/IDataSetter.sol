// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0xeb4b73bb`
interface IDataSetter {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event DataUpdated(
        bytes32 indexed node,
        bytes name,
        string indexed keyHash,
        string key,
        bytes value
    );

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set data for `key`.
    /// @param name The DNS-encoded name.
    /// @param key The data key.
    /// @param value The data value.
    function setData(bytes calldata name, string calldata key, bytes calldata value) external;
}
