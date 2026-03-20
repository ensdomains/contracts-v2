// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IEnhancedAccessControl} from "../../access-control/interfaces/IEnhancedAccessControl.sol";

import {IRecordResolver} from "./IRecordResolver.sol";

/// @dev The complete interface selector: `0x5999b442`
bytes4 constant PERMISSIONED_RESOLVER_INTERFACE_ID = type(IPermissionedResolver).interfaceId ^
    type(IEnhancedAccessControl).interfaceId ^
    type(IRecordResolver).interfaceId;

/// @dev Interface selector: `0x899f136b`
interface IPermissionedResolver is IEnhancedAccessControl, IRecordResolver {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Associate `recordId` with optional `setterPrefix` with an EAC resource.
    event RecordResource(uint256 indexed recordId, uint256 indexed resource, bytes setterPrefix);

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

    /// @notice Grant `arg`-depenendant setter permission to `account` for record of `name`.
    /// @param setterPrefix The ABI-encoded setter calldata (`f(name, <arg>, ...)`) with optional data.
    /// @param account The account to be granted roles.
    /// @return `true` if role is granted.
    function grantSetterRoles(bytes calldata setterPrefix, address account) external returns (bool);
}
