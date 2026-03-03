// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Errors for migration process.
library MigrationErrors {
    /// @notice Name cannot be registered because unmigrated NameWrapper token exists.
    /// @dev Error selector: `0x408fa1b8`
    error NameRequiresMigration();

    /// @notice NameWrapper token was not locked.
    /// @dev Error selector: `0x1bfe8f0a`
    error NameNotLocked(uint256 tokenId);

    /// @notice NameWrapper token does not match supplied data.
    /// @dev Error selector: `0xedec3569`
    error NameDataMismatch(uint256 tokenId);
}
