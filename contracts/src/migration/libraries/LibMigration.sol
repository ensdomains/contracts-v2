// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    CAN_EXTEND_EXPIRY,
    CANNOT_BURN_FUSES,
    CANNOT_CREATE_SUBDOMAIN,
    CANNOT_SET_RESOLVER,
    CANNOT_TRANSFER,
    CANNOT_UNWRAP,
    IS_DOT_ETH,
    PARENT_CANNOT_CONTROL
} from "@ens/contracts/wrapper/INameWrapper.sol";

import {IRegistry} from "../../registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "../../registry/libraries/RegistryRolesLib.sol";

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

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns `true` if the NameWrapper token is locked.
    function isLocked(uint32 fuses) internal pure returns (bool) {
        // PARENT_CANNOT_CONTROL is required to set CANNOT_UNWRAP, so CANNOT_UNWRAP is sufficient
        // see: V1Fixture.t.sol: `test_nameWrapper_CANNOT_UNWRAP_requires_PARENT_CANNOT_CONTROL()`
        return (fuses & CANNOT_UNWRAP) != 0;
    }

    /// @dev Returns `true` if the NameWrapper token fuses are not frozen.
    function notFrozen(uint32 fuses) internal pure returns (bool) {
        return (fuses & CANNOT_BURN_FUSES) == 0;
    }

    /// @dev Returns `true` if the NameWrapper token is emancipated and not 2LD .eth.
    function isEmancipatedChild(uint32 fuses) internal pure returns (bool) {
        // PARENT_CANNOT_CONTROL must be set for the entire ancestory.
        // see: V1Fixture.t.sol: `test_nameWrapper_PARENT_CANNOT_CONTROL_withoutParent()`
        return (fuses & (IS_DOT_ETH | PARENT_CANNOT_CONTROL)) == PARENT_CANNOT_CONTROL;
    }

    /// @dev Convert fuses to equivalent subregistry root roles.
    function subregistryRoleBitmapFromFuses(uint32 fuses)
        internal
        pure
        returns (uint256 roleBitmap)
    {
        if ((fuses & CANNOT_CREATE_SUBDOMAIN) == 0) {
            roleBitmap |= RegistryRolesLib.ROLE_REGISTRAR;
        }
        roleBitmap |=
            RegistryRolesLib.ROLE_RENEW |
            RegistryRolesLib.ROLE_UPGRADE |
            RegistryRolesLib.ROLE_CAN_NAME;
        if (notFrozen(fuses)) {
            roleBitmap |= roleBitmap << 128; // give admin
        }
    }

    /// @dev Convert fuses to equivalent token roles.
    function tokenRoleBitmapFromFuses(uint32 fuses) internal pure returns (uint256 roleBitmap) {
        if ((fuses & CAN_EXTEND_EXPIRY) != 0) {
            roleBitmap |= RegistryRolesLib.ROLE_RENEW;
        }
        if ((fuses & CANNOT_SET_RESOLVER) == 0) {
            roleBitmap |= RegistryRolesLib.ROLE_SET_RESOLVER;
        }
        if (notFrozen(fuses)) {
            roleBitmap |= roleBitmap << 128; // give admin
        }
        if ((fuses & CANNOT_TRANSFER) == 0) {
            roleBitmap |= RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN; // no user
        }
    }
}
