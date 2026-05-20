// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice Interface for a shared label database.
/// @dev Interface selector: `0x0d48fe93`
interface ILabelStore {
    /// @notice A label was recorded.
    /// @param labelHash The hash of `label`.
    /// @param label The recorded label.
    event Label(bytes32 indexed labelHash, string label);

    /// @notice Ensure `label` can be inverted from `anyId`.
    /// @param label The label.
    function setLabel(string calldata label) external;

    /// @notice Invert `anyId` to the corresponding label.
    /// @param anyId The truncated labelhash.
    /// @return The label or null if unknown.
    function getLabel(uint256 anyId) external view returns (string memory);
}
