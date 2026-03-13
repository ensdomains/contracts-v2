// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "../../registry/interfaces/IRegistry.sol";

/// @dev Primitives for migration.
library LibMigration {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev Typed arguments for migration via transfer payload.
    struct Data {
        /// @dev Subdomain being migrated.
        string label;
        /// @dev Address that will own the name in the v2 registry.
        address owner;
        /// @dev Address of the child registry.
        ///      Ignored by locked migration.
        IRegistry subregistry;
        /// @dev Resolver address to set for the migrated name.
        ///      Ignored if locked and `CANNOT_SET_RESOLVER`.
        address resolver;
    }

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Minimum size of `abi.encode(Data({...}))`.
    uint256 internal constant MIN_DATA_SIZE = 7 * 32;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Name cannot be registered because unmigrated NameWrapper token exists.
    /// @dev Error selector: `0x408fa1b8`
    error NameRequiresMigration();

    /// @notice NameWrapper token is unlocked.
    /// @dev Error selector: `0x1bfe8f0a`
    error NameNotLocked(uint256 tokenId);

    /// @notice NameWrapper token is locked.
    /// @dev Error selector: `0xe7c290e2`
    error NameIsLocked(uint256 tokenId);

    /// @notice NameWrapper or BaseRegistrar token does not match supplied data.
    /// @dev Error selector: `0xedec3569`
    error NameDataMismatch(uint256 tokenId);

    /// @notice NameWrapper token has existing approval and burned `CANNOT_APPROVE`.
    /// @dev Error selector: `0xa4f07713`
    error FrozenTokenApproval(uint256 tokenId);

    /// @notice The encoded data is invalid.
    /// @dev Error selector: `0x5cb045db`
    error InvalidData();
}
