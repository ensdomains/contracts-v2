// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "../../registry/interfaces/IRegistry.sol";

library LibMigration {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev Typed arguments for ERC-721 ".eth" token migration.
    struct UnlockedData {
        string label;
        address owner;
        IRegistry subregistry;
        address resolver;
    }

    /// @dev Typed arguments for NameWrapper token migration.
    struct LockedData {
        string label;
        address owner;
        address resolver;
        uint256 salt;
    }

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Minimum Size of `abi.encode(UnlockedData({...}))`.
    uint256 constant MIN_UNLOCKED_DATA_SIZE = 7 * 32;

    /// @dev Minimum Size of `abi.encode(LockedData({...}))`.
    uint256 constant MIN_LOCKED_DATA_SIZE = 7 * 32;

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

    /// @notice NameWrapper token does not match supplied data.
    /// @dev Error selector: `0xedec3569`
    error NameDataMismatch(uint256 tokenId);

    /// @notice The encoded data is invalid.
    /// @dev Error selector: `0x5cb045db`
    error InvalidData();
}
