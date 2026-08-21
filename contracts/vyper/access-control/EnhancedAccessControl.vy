# pragma version ~=0.4.3
# SPDX-License-Identifier: MIT

from .libraries import EACBaseRolesLib as roles_lib

ROOT_RESOURCE: constant(uint256) = 0

_roles: HashMap[uint256, HashMap[address, uint256]]
_role_count: HashMap[uint256, uint256]

# Preserves the externally observable Solidity event ABI.
event EACRolesChanged:
    resource: indexed(uint256)
    account: indexed(address)
    oldRoleBitmap: uint256
    newRoleBitmap: uint256

# -------------------------------------------------------------------------
# Override points corresponding to Solidity virtual functions.
# -------------------------------------------------------------------------

@abstract
@view
def _get_roles(resource: uint256, account: address) -> uint256:
    ...

@abstract
@view
def _get_settable_roles(resource: uint256, account: address) -> uint256:
    ...

@abstract
def _on_roles_granted(resource: uint256, account: address, old_roles: uint256, new_roles: uint256, role_bitmap: uint256):
    ...

@abstract
def _on_roles_revoked(resource: uint256, account: address, old_roles: uint256, new_roles: uint256, role_bitmap: uint256):
    ...

# -------------------------------------------------------------------------
# Exact Solidity custom-error encoders.
# -------------------------------------------------------------------------

@internal
@pure
def _error_unauthorized(resource: uint256, role_bitmap: uint256, account: address):
    raw_revert(abi_encode(resource, role_bitmap, account, method_id=method_id("EACUnauthorizedAccountRoles(uint256,uint256,address)")))

@internal
@pure
def _error_cannot_grant(resource: uint256, role_bitmap: uint256, account: address):
    raw_revert(abi_encode(resource, role_bitmap, account, method_id=method_id("EACCannotGrantRoles(uint256,uint256,address)")))

@internal
@pure
def _error_cannot_revoke(resource: uint256, role_bitmap: uint256, account: address):
    raw_revert(abi_encode(resource, role_bitmap, account, method_id=method_id("EACCannotRevokeRoles(uint256,uint256,address)")))

@internal
@pure
def _error_root_resource_not_allowed():
    raw_revert(method_id("EACRootResourceNotAllowed()"))

@internal
@pure
def _error_max_assignees(resource: uint256, role_bitmap: uint256):
    raw_revert(abi_encode(resource, role_bitmap, method_id=method_id("EACMaxAssignees(uint256,uint256)")))

@internal
@pure
def _error_min_assignees(resource: uint256, role_bitmap: uint256):
    raw_revert(abi_encode(resource, role_bitmap, method_id=method_id("EACMinAssignees(uint256,uint256)")))

@internal
@pure
def _error_invalid_role_bitmap(role_bitmap: uint256):
    raw_revert(abi_encode(role_bitmap, method_id=method_id("EACInvalidRoleBitmap(uint256)")))

@internal
@pure
def _error_invalid_account():
    raw_revert(method_id("EACInvalidAccount()"))

# -------------------------------------------------------------------------
# Public API implementation. These functions can be exported by consumers.
# -------------------------------------------------------------------------

@external
def grantRoles(resource: uint256, role_bitmap: uint256, account: address) -> bool:
    self._check_can_grant_roles(resource, role_bitmap, msg.sender)
    if resource == ROOT_RESOURCE:
        self._error_root_resource_not_allowed()
    return self._grant_roles(resource, role_bitmap, account, True)

@external
def grantRootRoles(role_bitmap: uint256, account: address) -> bool:
    self._check_can_grant_roles(ROOT_RESOURCE, role_bitmap, msg.sender)
    return self._grant_roles(ROOT_RESOURCE, role_bitmap, account, True)

@external
def revokeRoles(resource: uint256, role_bitmap: uint256, account: address) -> bool:
    self._check_can_revoke_roles(resource, role_bitmap, msg.sender)
    if resource == ROOT_RESOURCE:
        self._error_root_resource_not_allowed()
    return self._revoke_roles(resource, role_bitmap, account, True)

@external
def revokeRootRoles(role_bitmap: uint256, account: address) -> bool:
    self._check_can_revoke_roles(ROOT_RESOURCE, role_bitmap, msg.sender)
    return self._revoke_roles(ROOT_RESOURCE, role_bitmap, account, True)

@external
@view
def ROOT_RESOURCE() -> uint256:
    return ROOT_RESOURCE

@external
@view
def roles(resource: uint256, account: address) -> uint256:
    return self._get_roles(resource, account)

@external
@view
def roleCount(resource: uint256) -> uint256:
    return self._role_count[resource]

@external
@view
def hasRootRoles(role_bitmap: uint256, account: address) -> bool:
    return self._get_roles(ROOT_RESOURCE, account) & role_bitmap == role_bitmap

@external
@view
def hasRoles(resource: uint256, role_bitmap: uint256, account: address) -> bool:
    return self._effective_roles(resource, account) & role_bitmap == role_bitmap

@external
@view
def hasAssignees(resource: uint256, role_bitmap: uint256) -> bool:
    counts: uint256 = 0
    mask: uint256 = 0
    counts, mask = self._get_assignee_count(resource, role_bitmap)
    return counts != 0

@external
@view
def getAssigneeCount(resource: uint256, role_bitmap: uint256) -> (uint256, uint256):
    return self._get_assignee_count(resource, role_bitmap)

# -------------------------------------------------------------------------
# Internal API used by concrete registries/resolvers.
# -------------------------------------------------------------------------

@internal
@view
def _stored_roles(resource: uint256, account: address) -> uint256:
    return self._roles[resource][account]

@internal
@view
def _default_settable_roles(resource: uint256, account: address) -> uint256:
    return roles_lib.with_admin_roles_applied(self._effective_roles(resource, account))

@internal
@view
def _default_revokable_roles(resource: uint256, account: address) -> uint256:
    return roles_lib.with_admin_roles_applied(self._effective_roles(resource, account))

@internal
def _transfer_roles(resource: uint256, src_account: address, dst_account: address, execute_callbacks: bool):
    src_roles: uint256 = self._roles[resource][src_account]
    if src_roles != 0:
        self._revoke_roles(resource, src_roles, src_account, execute_callbacks)
        self._grant_roles(resource, src_roles, dst_account, execute_callbacks)

@internal
def _grant_roles(resource: uint256, role_bitmap: uint256, account: address, execute_callbacks: bool) -> bool:
    if role_bitmap == 0:
        return False
    self._check_role_bitmap(role_bitmap)
    if account == empty(address):
        self._error_invalid_account()

    current_roles: uint256 = self._roles[resource][account]
    updated_roles: uint256 = current_roles | role_bitmap
    if current_roles == updated_roles:
        return False

    self._roles[resource][account] = updated_roles
    newly_added_roles: uint256 = role_bitmap & ~current_roles
    self._update_role_counts(resource, newly_added_roles, True)
    log EACRolesChanged(resource, account, current_roles, updated_roles)
    if execute_callbacks:
        self._on_roles_granted(resource, account, current_roles, updated_roles, role_bitmap)
    return True

@internal
def _revoke_roles(resource: uint256, role_bitmap: uint256, account: address, execute_callbacks: bool) -> bool:
    self._check_role_bitmap(role_bitmap)
    current_roles: uint256 = self._roles[resource][account]
    updated_roles: uint256 = current_roles & ~role_bitmap
    if current_roles == updated_roles:
        return False

    self._roles[resource][account] = updated_roles
    newly_removed_roles: uint256 = role_bitmap & current_roles
    self._update_role_counts(resource, newly_removed_roles, False)
    log EACRolesChanged(resource, account, current_roles, updated_roles)
    if execute_callbacks:
        self._on_roles_revoked(resource, account, current_roles, updated_roles, role_bitmap)
    return True

@internal
def _update_role_counts(resource: uint256, role_bitmap: uint256, is_grant: bool):
    role_mask: uint256 = self._role_bitmap_to_mask(role_bitmap)
    if is_grant:
        if roles_lib.has_zero_nybbles(~(role_mask & self._role_count[resource])):
            self._error_max_assignees(resource, role_bitmap)
        self._role_count[resource] += role_bitmap
    else:
        if roles_lib.has_zero_nybbles(~(role_mask & ~self._role_count[resource])):
            self._error_min_assignees(resource, role_bitmap)
        self._role_count[resource] -= role_bitmap

@internal
@view
def _check_roles(resource: uint256, role_bitmap: uint256, account: address):
    if self._effective_roles(resource, account) & role_bitmap != role_bitmap:
        self._error_unauthorized(resource, role_bitmap, account)

@internal
@view
def _check_can_grant_roles(resource: uint256, role_bitmap: uint256, account: address):
    settable_roles: uint256 = self._get_settable_roles(resource, account)
    if role_bitmap & ~settable_roles != 0:
        self._error_cannot_grant(resource, role_bitmap, account)

@internal
@view
def _check_can_revoke_roles(resource: uint256, role_bitmap: uint256, account: address):
    revokable_roles: uint256 = self._default_revokable_roles(resource, account)
    if role_bitmap & ~revokable_roles != 0:
        self._error_cannot_revoke(resource, role_bitmap, account)

@internal
@view
def _effective_roles(resource: uint256, account: address) -> uint256:
    return self._get_roles(ROOT_RESOURCE, account) | self._get_roles(resource, account)

@internal
@view
def _get_assignee_count(resource: uint256, role_bitmap: uint256) -> (uint256, uint256):
    mask: uint256 = self._role_bitmap_to_mask(role_bitmap)
    return self._role_count[resource] & mask, mask

@internal
@pure
def _check_role_bitmap(role_bitmap: uint256):
    if role_bitmap & ~roles_lib.ALL_ROLES != 0:
        self._error_invalid_role_bitmap(role_bitmap)

@internal
@pure
def _role_bitmap_to_mask(role_bitmap: uint256) -> uint256:
    self._check_role_bitmap(role_bitmap)
    role_mask: uint256 = role_bitmap | (role_bitmap << 1)
    return role_mask | (role_mask << 2)
