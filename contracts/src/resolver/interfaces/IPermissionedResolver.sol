// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IEnhancedAccessControl} from "../../access-control/interfaces/IEnhancedAccessControl.sol";

import {IRecordResolver} from "./IRecordResolver.sol";

/// @dev The derived interface identifier.
bytes4 constant PERMISSIONED_RESOLVER_INTERFACE_ID = type(IPermissionedResolver).interfaceId ^
    type(IEnhancedAccessControl).interfaceId ^
    type(IRecordResolver).interfaceId;

/// @dev Interface selector: `0xd2f09e94`
interface IPermissionedResolver is IEnhancedAccessControl, IRecordResolver {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Associate `recordId` with optional `setterPrefix` with an EAC resource.
    event RecordResource(uint256 indexed recordId, uint256 indexed resource, bytes setterPrefix);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    function grantRecordRoles(
        uint256 recordId,
        uint256 roleBitmap,
        address account
    ) external returns (bool);

    function grantSetterRoles(
        uint256 recordId,
        bytes calldata setterPrefix,
        address account
    ) external returns (bool);
}
