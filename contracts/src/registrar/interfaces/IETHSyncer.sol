// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for syncing ENSv1 with ENSv2.
/// @dev Interface selector: `0x07b4403c`
interface IETHSyncer {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `label` cannot be synced.
    /// @dev Error selector: `0x9610019f`
    error NameNotSyncable(string label);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Sync `BaseRegistrar` expiry with ENSv2.
    /// @param label The label to sync.
    function syncRegistrar(string calldata label) external;

    /// @notice Sync `NameWrapper` expiry with `BaseRegistrar` expiry.
    /// @param labels The labels to sync.
    function syncWrapper(string[] calldata labels) external;
}
