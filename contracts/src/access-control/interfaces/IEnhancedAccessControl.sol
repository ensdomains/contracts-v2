// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

/**
 * @dev Interface for Enhanced Access Control system that allows for:
 * - Resource-based roles
 * - Obtaining assignee count for each role in each resource
 * - Root resource override
 * - Up to 32 roles and 32 corresponding admin roles
 * - Up to 15 assignees per role
 */
interface IEnhancedAccessControl is IERC165 {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event EACRolesChanged(
        uint256 indexed resource,
        address indexed account,
        uint256 oldRoleBitmap,
        uint256 newRoleBitmap
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error EACUnauthorizedAccountRoles(uint256 resource, uint256 roleBitmap, address account);

    error EACCannotGrantRoles(uint256 resource, uint256 roleBitmap, address account);

    error EACCannotRevokeRoles(uint256 resource, uint256 roleBitmap, address account);

    error EACRootResourceNotAllowed();

    error EACMaxAssignees(uint256 resource, uint256 role);

    error EACMinAssignees(uint256 resource, uint256 role);

    error EACInvalidRoleBitmap(uint256 roleBitmap);

    error EACInvalidAccount();

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /**
     * @dev Grants all roles in the given role bitmap to `account`.
     */
    function grantRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account
    ) external returns (bool);

    /**
     * @dev Grants all roles in the given role bitmap to `account` in the ROOT_RESOURCE.
     */
    function grantRootRoles(uint256 roleBitmap, address account) external returns (bool);

    /**
     * @dev Revokes all roles in the given role bitmap from `account`.
     */
    function revokeRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account
    ) external returns (bool);

    /**
     * @dev Revokes all roles in the given role bitmap from `account` in the ROOT_RESOURCE.
     */
    function revokeRootRoles(uint256 roleBitmap, address account) external returns (bool);

    /**
     * @dev Returns the `ROOT_RESOURCE` constant.
     */
    function ROOT_RESOURCE() external view returns (uint256);

    /**
     * @dev Returns the roles bitmap for an account in a resource.
     */
    function roles(uint256 resource, address account) external view returns (uint256);

    /**
     * @dev Returns the role count bitmap for a resource.
     */
    function roleCount(uint256 resource) external view returns (uint256);

    /**
     * @dev Returns `true` if `account` has been granted all the given roles in the `ROOT_RESOURCE`.
     */
    function hasRootRoles(uint256, address account) external view returns (bool);

    /**
     * @dev Returns `true` if `account` has been granted all the given roles in `resource`.
     */
    function hasRoles(uint256 resource, uint256, address account) external view returns (bool);

    /**
     * @dev Get if any of the roles in the given role bitmap has assignees.
     */
    function hasAssignees(uint256 resource, uint256 roleBitmap) external view returns (bool);

    /**
     * @dev Get the no. of assignees for the roles in the given role bitmap.
     */
    function getAssigneeCount(
        uint256 resource,
        uint256 roleBitmap
    ) external view returns (uint256 counts, uint256 mask);
}
