// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "../../registry/interfaces/IRegistry.sol";

library LibMigration {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev Typed arguments for migration.
    struct Data {
        string label;
        address owner;
        address resolver;
        IRegistry subregistry; // ignored if locked
        uint256 salt; // ignored if unlocked
    }

    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Minimum Size of `abi.encode(Data({...}))`.
    uint256 constant MIN_DATA_SIZE = 8 * 32;

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
