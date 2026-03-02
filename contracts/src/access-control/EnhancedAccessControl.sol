// SPDX-License-Identifier: MIT
// OpenZeppelin Contracts (access/AccessControl.sol)

pragma solidity ^0.8.20;

import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {HCAContext} from "../hca/HCAContext.sol";

import {IEnhancedAccessControl} from "./interfaces/IEnhancedAccessControl.sol";
import {EACBaseRolesLib} from "./libraries/EACBaseRolesLib.sol";

/// @dev Access control system that allows for:
///
///      - Resource-based roles.
///      - Obtaining assignee count for each role in each resource.
///      - Root resource override (0x0) - role assignments in the `ROOT_RESOURCE` auto-apply to all resources.
///      - Up to 32 roles and 32 corresponding admin roles - stored as a bitmap in uint256 (see below).
///      - Up to 15 assignees per role - stored as a bitmap in uint256 (64 * 4 bits = 256 bits) (see below).
///
///      Role representation:
///      - A role bitmap is a uint256, where the lower 128 bits represent the regular roles (0-31), and the upper 128 bits represent the admin roles (32-63) for those roles.
///      - Each role is represented by a nybble (4 bits), in little-endian order.
///      - If a given role left-most nybble bit is located at index N then the corresponding admin role nybble starts at bit position N << 128.
abstract contract EnhancedAccessControl is HCAContext, ERC165, IEnhancedAccessControl {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The `ROOT_RESOURCE`.
    uint256 public constant ROOT_RESOURCE = 0;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev user roles within a resource stored as a bitmap.
    ///      Resource -> User -> RoleBitmap
    mapping(uint256 resource => mapping(address account => uint256 roleBitmap)) private _roles;

    /// @dev The number of assignees for a given role in a given resource.
    ///
    ///      Each role's count is represented by 4 bits, in little-endian order.
    ///      This results in max. 64 roles, and 15 assignees per role.
    mapping(uint256 resource => uint256 roleCount) private _roleCount;

    ////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Modifier that checks that sender has the admin roles for all the given roles.
    modifier canGrantRoles(uint256 resource, uint256 roleBitmap) {
        _checkCanGrantRoles(resource, roleBitmap, _msgSender());
        _;
    }

    /// @dev Modifier that checks that sender has the admin roles for all the given roles and can revoke them.
    modifier canRevokeRoles(uint256 resource, uint256 roleBitmap) {
        _checkCanRevokeRoles(resource, roleBitmap, _msgSender());
        _;
    }

    /// @dev Modifier that checks that sender has all the given roles within the given resource.
    modifier onlyRoles(uint256 resource, uint256 roleBitmap) {
        _checkRoles(resource, roleBitmap, _msgSender());
        _;
    }

    /// @dev Modifier that checks that sender has all the given roles within the `ROOT_RESOURCE`.
    modifier onlyRootRoles(uint256 roleBitmap) {
        _checkRoles(ROOT_RESOURCE, roleBitmap, _msgSender());
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IEnhancedAccessControl).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////
    /// @dev Grants all roles in the given role bitmap to `account`.
    ///
    /// The caller must have all the necessary admin roles for the roles being granted.
    /// Cannot be used with ROOT_RESOURCE directly, use grantRootRoles instead.
    ///
    /// @param resource The resource to grant roles within.
    /// @param roleBitmap The roles bitmap to grant.
    /// @param account The account to grant roles to.
    /// @return `true` if the roles were granted, `false` otherwise.
    function grantRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account
    ) public virtual canGrantRoles(resource, roleBitmap) returns (bool) {
        if (resource == ROOT_RESOURCE) {
            revert EACRootResourceNotAllowed();
        }
        return _grantRoles(resource, roleBitmap, account, true);
    }

    /// @dev Grants all roles in the given role bitmap to `account` in the ROOT_RESOURCE.
    ///
    /// The caller must have all the necessary admin roles for the roles being granted.
    ///
    /// @param roleBitmap The roles bitmap to grant.
    /// @param account The account to grant roles to.
    /// @return `true` if the roles were granted, `false` otherwise.
    function grantRootRoles(
        uint256 roleBitmap,
        address account
    ) public virtual canGrantRoles(ROOT_RESOURCE, roleBitmap) returns (bool) {
        return _grantRoles(ROOT_RESOURCE, roleBitmap, account, true);
    }

    /// @dev Revokes all roles in the given role bitmap from `account`.
    ///
    /// The caller must have all the necessary admin roles for the roles being revoked.
    /// Cannot be used with ROOT_RESOURCE directly, use revokeRootRoles instead.
    ///
    /// @param resource The resource to revoke roles within.
    /// @param roleBitmap The roles bitmap to revoke.
    /// @param account The account to revoke roles from.
    /// @return `true` if the roles were revoked, `false` otherwise.
    function revokeRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account
    ) public virtual canRevokeRoles(resource, roleBitmap) returns (bool) {
        if (resource == ROOT_RESOURCE) {
            revert EACRootResourceNotAllowed();
        }
        return _revokeRoles(resource, roleBitmap, account, true);
    }

    /// @dev Revokes all roles in the given role bitmap from `account` in the ROOT_RESOURCE.
    ///
    /// The caller must have all the necessary admin roles for the roles being revoked.
    ///
    /// @param roleBitmap The roles bitmap to revoke.
    /// @param account The account to revoke roles from.
    /// @return `true` if the roles were revoked, `false` otherwise.
    function revokeRootRoles(
        uint256 roleBitmap,
        address account
    ) public virtual canRevokeRoles(ROOT_RESOURCE, roleBitmap) returns (bool) {
        return _revokeRoles(ROOT_RESOURCE, roleBitmap, account, true);
    }

    /// @notice Returns the roles bitmap for an account in a resource.
    function roles(uint256 resource, address account) public view virtual returns (uint256) {
        return _roles[resource][account];
    }

    /// @notice Returns the role count bitmap for a resource.
    function roleCount(uint256 resource) public view virtual returns (uint256) {
        return _roleCount[resource];
    }

    /// @dev Returns `true` if `account` has been granted all the given roles in the `ROOT_RESOURCE`.
    ///
    /// @param roleBitmap The roles bitmap to check.
    /// @param account The account to check.
    /// @return `true` if `account` has been granted all the given roles in the `ROOT_RESOURCE`, `false` otherwise.
    function hasRootRoles(uint256 roleBitmap, address account) public view virtual returns (bool) {
        return _roles[ROOT_RESOURCE][account] & roleBitmap == roleBitmap;
    }

    /// @dev Returns `true` if `account` has been granted all the given roles in `resource`.
    ///
    /// @param resource The resource to check.
    /// @param roleBitmap The roles bitmap to check.
    /// @param account The account to check.
    /// @return `true` if `account` has been granted all the given roles in either `resource` or the `ROOT_RESOURCE`, `false` otherwise.
    function hasRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account
    ) public view virtual returns (bool) {
        return
            (_roles[ROOT_RESOURCE][account] | _roles[resource][account]) & roleBitmap == roleBitmap;
    }

    /// @dev Get if any of the roles in the given role bitmap has assignees.
    ///
    /// @param resource The resource to check.
    /// @param roleBitmap The roles bitmap to check.
    /// @return `true` if any of the roles in the given role bitmap has assignees, `false` otherwise.
    function hasAssignees(uint256 resource, uint256 roleBitmap) public view virtual returns (bool) {
        (uint256 counts, ) = getAssigneeCount(resource, roleBitmap);
        return counts != 0;
    }

    /// @dev Get the no. of assignees for the roles in the given role bitmap.
    ///
    /// @param resource The resource to check.
    /// @param roleBitmap The roles bitmap to check.
    /// @return counts The no. of assignees for each of the roles in the given role bitmap, expressed as a packed array of 4-bit ints.
    /// @return mask The mask for the given role bitmap.
    function getAssigneeCount(
        uint256 resource,
        uint256 roleBitmap
    ) public view virtual returns (uint256 counts, uint256 mask) {
        mask = _roleBitmapToMask(roleBitmap);
        counts = _roleCount[resource] & mask;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Transfers all roles from `srcAccount` to `dstAccount` within the same resource.
    ///
    /// This function first revokes all roles from the source account, then grants them to the
    /// destination account. This prevents exceeding max assignees limits during transfer.
    ///
    /// Does nothing if there are no roles to transfer.
    ///
    /// @param resource The resource to transfer roles within.
    /// @param srcAccount The account to transfer roles from.
    /// @param dstAccount The account to transfer roles to.
    /// @param executeCallbacks Whether to execute the callbacks.
    function _transferRoles(
        uint256 resource,
        address srcAccount,
        address dstAccount,
        bool executeCallbacks
    ) internal virtual {
        uint256 srcRoles = _roles[resource][srcAccount];
        if (srcRoles != 0) {
            // First revoke roles from source account to free up assignee slots
            _revokeRoles(resource, srcRoles, srcAccount, executeCallbacks);
            // Then grant roles to destination account
            _grantRoles(resource, srcRoles, dstAccount, executeCallbacks);
        }
    }

    /// @dev Grants multiple roles to `account`.
    ///
    /// @param resource The resource to grant roles within.
    /// @param roleBitmap The roles bitmap to grant.
    /// @param account The account to grant roles to.
    /// @param executeCallbacks Whether to execute the callbacks.
    /// @return `true` if the roles were granted, `false` otherwise.
    function _grantRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account,
        bool executeCallbacks
    ) internal virtual returns (bool) {
        _checkRoleBitmap(roleBitmap);
        if (account == address(0)) {
            revert EACInvalidAccount();
        }
        uint256 currentRoles = _roles[resource][account];
        uint256 updatedRoles = currentRoles | roleBitmap;

        if (currentRoles != updatedRoles) {
            _roles[resource][account] = updatedRoles;
            uint256 newlyAddedRoles = roleBitmap & ~currentRoles;
            _updateRoleCounts(resource, newlyAddedRoles, true);
            if (executeCallbacks) {
                _onRolesGranted(resource, account, currentRoles, updatedRoles, roleBitmap);
            }
            emit EACRolesChanged(resource, account, currentRoles, updatedRoles);
            return true;
        } else {
            return false;
        }
    }

    /// @dev Attempts to revoke roles from `account` and returns a boolean indicating if roles were revoked.
    ///
    /// @param resource The resource to revoke roles within.
    /// @param roleBitmap The roles bitmap to revoke.
    /// @param account The account to revoke roles from.
    /// @param executeCallbacks Whether to execute the callbacks.
    /// @return `true` if the roles were revoked, `false` otherwise.
    function _revokeRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account,
        bool executeCallbacks
    ) internal virtual returns (bool) {
        _checkRoleBitmap(roleBitmap);
        uint256 currentRoles = _roles[resource][account];
        uint256 updatedRoles = currentRoles & ~roleBitmap;

        if (currentRoles != updatedRoles) {
            _roles[resource][account] = updatedRoles;
            uint256 newlyRemovedRoles = roleBitmap & currentRoles;
            _updateRoleCounts(resource, newlyRemovedRoles, false);
            if (executeCallbacks) {
                _onRolesRevoked(resource, account, currentRoles, updatedRoles, roleBitmap);
            }
            emit EACRolesChanged(resource, account, currentRoles, updatedRoles);
            return true;
        } else {
            return false;
        }
    }

    /// @dev Revoke all roles for account within resource.
    function _revokeAllRoles(
        uint256 resource,
        address account,
        bool executeCallbacks
    ) internal virtual returns (bool) {
        return _revokeRoles(resource, EACBaseRolesLib.ALL_ROLES, account, executeCallbacks);
    }

    /// @dev Updates role counts when roles are granted/revoked
    /// @param resource The resource to update counts for
    /// @param roleBitmap The roles being modified
    /// @param isGrant true for grant, false for revoke
    function _updateRoleCounts(uint256 resource, uint256 roleBitmap, bool isGrant) internal {
        uint256 roleMask = _roleBitmapToMask(roleBitmap);

        if (isGrant) {
            // Check for overflow
            if (_hasZeroNybbles(~(roleMask & _roleCount[resource]))) {
                revert EACMaxAssignees(resource, roleBitmap);
            }
            _roleCount[resource] += roleBitmap;
        } else {
            // Check for underflow
            if (_hasZeroNybbles(~(roleMask & ~_roleCount[resource]))) {
                revert EACMinAssignees(resource, roleBitmap);
            }
            _roleCount[resource] -= roleBitmap;
        }
    }

    /// @dev Callback for when roles are granted.
    ///
    /// @param resource The resource that the roles were granted within.
    /// @param account The account that the roles were granted to.
    /// @param oldRoles The old roles for the account.
    /// @param newRoles The new roles for the account.
    /// @param roleBitmap The roles that were granted.
    function _onRolesGranted(
        uint256 resource,
        address account,
        uint256 oldRoles,
        uint256 newRoles,
        uint256 roleBitmap
    ) internal virtual {
        // solhint-disable-previous-line no-empty-blocks
    }

    /// @dev Callback for when roles are revoked.
    ///
    /// @param resource The resource that the roles were revoked within.
    /// @param account The account that the roles were revoked from.
    /// @param oldRoles The old roles for the account.
    /// @param newRoles The new roles for the account.
    /// @param roleBitmap The roles that were revoked.
    function _onRolesRevoked(
        uint256 resource,
        address account,
        uint256 oldRoles,
        uint256 newRoles,
        uint256 roleBitmap
    ) internal virtual {
        // solhint-disable-previous-line no-empty-blocks
    }

    /// @dev Reverts if `account` does not have all the given roles.
    function _checkRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account
    ) internal view virtual {
        if (!hasRoles(resource, roleBitmap, account)) {
            revert EACUnauthorizedAccountRoles(resource, roleBitmap, account);
        }
    }

    /// @dev Reverts if `account` does not have the admin roles for all the given roles.
    function _checkCanGrantRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account
    ) internal view virtual {
        uint256 settableRoles = _getSettableRoles(resource, account);
        if ((roleBitmap & ~settableRoles) != 0) {
            revert EACCannotGrantRoles(resource, roleBitmap, account);
        }
    }

    /// @dev Reverts if `account` does not have the admin roles for all the given roles that are being revoked.
    function _checkCanRevokeRoles(
        uint256 resource,
        uint256 roleBitmap,
        address account
    ) internal view virtual {
        uint256 revokableRoles = _getRevokableRoles(resource, account);
        if ((roleBitmap & ~revokableRoles) != 0) {
            revert EACCannotRevokeRoles(resource, roleBitmap, account);
        }
    }

    /// @dev Returns the settable roles for `account` within `resource`.
    ///
    /// The settable roles are the roles (both regular and admin) that the account can grant.
    /// An account can grant a regular role if they have the corresponding admin role.
    /// An account can grant an admin role if they have that same admin role.
    ///
    /// @param resource The resource to get settable roles for.
    /// @param account The account to get settable roles for.
    /// @return The settable roles for `account` within `resource`.
    function _getSettableRoles(
        uint256 resource,
        address account
    ) internal view virtual returns (uint256) {
        uint256 adminRoleBitmap = (_roles[resource][account] | _roles[ROOT_RESOURCE][account]) &
            EACBaseRolesLib.ADMIN_ROLES;
        return (adminRoleBitmap >> 128) | adminRoleBitmap;
    }

    /// @dev Returns the revokable roles for `account` within `resource`.
    ///
    /// The revokable roles are the roles (including admin roles) that the account can revoke.
    /// Unlike settable roles, this includes admin roles that can be revoked.
    ///
    /// @param resource The resource to get revokable roles for.
    /// @param account The account to get revokable roles for.
    /// @return The revokable roles for `account` within `resource`.
    function _getRevokableRoles(
        uint256 resource,
        address account
    ) internal view virtual returns (uint256) {
        uint256 adminRoleBitmap = (_roles[resource][account] | _roles[ROOT_RESOURCE][account]) &
            EACBaseRolesLib.ADMIN_ROLES;
        uint256 regularRoles = adminRoleBitmap >> 128;
        return regularRoles | adminRoleBitmap;
    }

    ////////////////////////////////////////////////////////////////////////
    // Private Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Checks if a role bitmap contains only valid role bits.
    ///
    /// @param roleBitmap The role bitmap to check.
    function _checkRoleBitmap(uint256 roleBitmap) private pure {
        if ((roleBitmap & ~EACBaseRolesLib.ALL_ROLES) != 0) {
            revert EACInvalidRoleBitmap(roleBitmap);
        }
    }

    /// @dev Converts a role bitmap to a mask.
    ///
    /// The mask is a bitmap where each nybble is set if the corresponding role is in the role bitmap.
    ///
    /// @param roleBitmap The role bitmap to convert.
    /// @return roleMask The mask for the role bitmap.
    function _roleBitmapToMask(uint256 roleBitmap) private pure returns (uint256 roleMask) {
        _checkRoleBitmap(roleBitmap);
        roleMask = roleBitmap | (roleBitmap << 1);
        roleMask |= roleMask << 2;
    }

    /// @dev Checks if the given value has any zero nybbles.
    ///
    /// @param value The value to check.
    /// @return `true` if the value has any zero nybbles, `false` otherwise.
    function _hasZeroNybbles(uint256 value) private pure returns (bool) {
        // Algorithm source: https://graphics.stanford.edu/~seander/bithacks.html#ZeroInWord
        uint256 hasZeroNybbles;
        unchecked {
            hasZeroNybbles =
                (value - 0x1111111111111111111111111111111111111111111111111111111111111111) &
                ~value &
                0x8888888888888888888888888888888888888888888888888888888888888888;
        }
        return hasZeroNybbles != 0;
    }
}
