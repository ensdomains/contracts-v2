// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IEnhancedAccessControl} from "../../access-control/interfaces/IEnhancedAccessControl.sol";

import {IRecordResolver, RECORD_RESOLVER_INTERFACE_ID} from "./IRecordResolver.sol";

/// @dev The complete interface selector: `0xf9e2cc41`
bytes4 constant PERMISSIONED_RESOLVER_INTERFACE_ID = RECORD_RESOLVER_INTERFACE_ID ^
    type(IPermissionedResolver).interfaceId ^
    type(IEnhancedAccessControl).interfaceId;

/// @dev Interface selector: `0x899f136b`
interface IPermissionedResolver is IEnhancedAccessControl, IRecordResolver {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Associate `recordId` with an EAC resource.
    /// @param recordId The record ID.
    /// @param resource The resource to associate.
    /// @param setter The ABI-encoded setter calldata.
    event RecordResource(uint256 indexed recordId, uint256 indexed resource, bytes setter);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Grant `roleBitmap` permissions to `account` for record of `name`.
    /// @param name The DNS-encoded name.
    /// @param roleBitmap The roles bitmap to grant.
    /// @param account The account to be granted roles.
    /// @return `true` if any roles are granted.
    function grantRecordRoles(
        bytes calldata name,
        uint256 roleBitmap,
        address account
    ) external returns (bool);

    /// @notice Grant fine-grained permission to `account` for record of `name`.
    /// @param setter The ABI-encoded setter calldata.
    /// @param account The account to be granted a role.
    /// @return `true` if a role is granted.
    function grantSetterRoles(bytes calldata setter, address account) external returns (bool);
}
