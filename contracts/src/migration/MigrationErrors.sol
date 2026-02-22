// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Errors for migration process.
library MigrationErrors {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error NameNotMigrated(bytes name);
    error NameNotLocked(uint256 tokenId);
    error NameDataMismatch(uint256 tokenId);
}
