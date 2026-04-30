// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for renewing names.
/// @dev Interface selector: `0x9ada16c3`
interface INameRenewer {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `label` was extended by `duration`.
    /// @param tokenId The registry token id.
    /// @param label The name of the renewal.
    /// @param duration The duration extension, in seconds.
    /// @param newExpiry The new expiry, in seconds.
    /// @param paymentToken The payment token.
    /// @param referrer The referrer hash.
    /// @param amount The amount of `paymentToken`.
    event NameRenewed(
        uint256 indexed tokenId,
        string label,
        uint64 duration,
        uint64 newExpiry,
        address paymentToken,
        bytes32 indexed referrer,
        uint256 amount
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `label` cannot be renewed.
    /// @dev Error selector: `0x1caefaa0`
    error NameNotRenewable(string label);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Renew a name.
    /// @dev Emits `NameRenewed` or reverts with a variety of errors.
    /// @param label The name to renew.
    /// @param duration The duration extension, in seconds.
    /// @param paymentToken The payment token.
    /// @param referrer The referrer hash.
    function renew(
        string memory label,
        uint64 duration,
        address paymentToken,
        bytes32 referrer
    ) external payable;

    /// @notice Determine if name can be renewed by this contract.
    /// @param label The name to renew.
    /// @return `true` if the name can be renewed.
    function isRenewable(string memory label) external view returns (bool);
}
