// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev The data for v1 to v2 transfers of a name.
struct TransferData {
    /// @dev DNS wire-format encoded name for the domain being migrated.
    bytes dnsEncodedName;
    /// @dev Address that will own the name in the v2 registry.
    address owner;
    /// @dev Address of the child registry (set by migration controller for locked names, or by caller for unlocked names).
    address subregistry;
    /// @dev Resolver address to set for the migrated name.
    address resolver;
    /// @dev Role bitmap to grant to the owner in the v2 registry.
    uint256 roleBitmap;
    /// @dev Expiration timestamp for the migrated name.
    uint64 expires;
}

/// @dev The data for v1 to v2 migrations of names.
struct MigrationData {
    /// @dev The name transfer parameters.
    TransferData transferData;
    /// @dev CREATE2 salt for deterministic subregistry deployment.
    uint256 salt;
}
