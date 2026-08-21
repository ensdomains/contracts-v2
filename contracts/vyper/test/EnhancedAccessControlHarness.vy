# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

from ..access_control import EnhancedAccessControl as EAC
from ..access_control.libraries import EACBaseRolesLib as roles_lib

initializes: EAC
exports: (
    EAC.grantRoles,
    EAC.grantRootRoles,
    EAC.revokeRoles,
    EAC.revokeRootRoles,
    EAC.ROOT_RESOURCE,
    EAC.roles,
    EAC.roleCount,
    EAC.hasRootRoles,
    EAC.hasRoles,
    EAC.hasAssignees,
    EAC.getAssigneeCount,
)

ROLE_A: constant(uint256) = 1
ROLE_B: constant(uint256) = 1 << 4
ROLE_C: constant(uint256) = 1 << 8
ROLE_D: constant(uint256) = 1 << 12
ADMIN_ROLE_A: constant(uint256) = ROLE_A << 128
ADMIN_ROLE_B: constant(uint256) = ROLE_B << 128
ADMIN_ROLE_C: constant(uint256) = ROLE_C << 128
ADMIN_ROLE_D: constant(uint256) = ROLE_D << 128
ALL_INITIAL_ROLES: constant(uint256) = ROLE_A | ROLE_B | ROLE_C | ROLE_D | ADMIN_ROLE_A | ADMIN_ROLE_B | ADMIN_ROLE_C | ADMIN_ROLE_D

lastGrantedCount: public(uint256)
lastGrantedRoleBitmap: public(uint256)
lastGrantedUpdatedRoles: public(uint256)
lastGrantedOldRoles: public(uint256)
lastGrantedNewRoles: public(uint256)
lastGrantedAccount: public(address)
lastGrantedResource: public(uint256)
lastRevokedCount: public(uint256)
lastRevokedRoleBitmap: public(uint256)
lastRevokedUpdatedRoles: public(uint256)
lastRevokedOldRoles: public(uint256)
lastRevokedNewRoles: public(uint256)
lastRevokedAccount: public(address)
lastRevokedResource: public(uint256)

@deploy
def __init__():
    EAC._grant_roles(EAC.ROOT_RESOURCE_VALUE, ALL_INITIAL_ROLES, msg.sender, True)
    self.lastGrantedCount = 0
    self.lastRevokedCount = 0

@override(EAC)
@view
def _get_roles(resource: uint256, account: address) -> uint256:
    return EAC._stored_roles(resource, account)

@override(EAC)
@view
def _get_settable_roles(resource: uint256, account: address) -> uint256:
    return EAC._default_settable_roles(resource, account)

@override(EAC)
def _on_roles_granted(resource: uint256, account: address, old_roles: uint256, new_roles: uint256, role_bitmap: uint256):
    self.lastGrantedCount += 1
    self.lastGrantedResource = resource
    self.lastGrantedRoleBitmap = role_bitmap
    self.lastGrantedOldRoles = old_roles
    self.lastGrantedNewRoles = new_roles
    self.lastGrantedUpdatedRoles = new_roles
    self.lastGrantedAccount = account

@override(EAC)
def _on_roles_revoked(resource: uint256, account: address, old_roles: uint256, new_roles: uint256, role_bitmap: uint256):
    self.lastRevokedCount += 1
    self.lastRevokedResource = resource
    self.lastRevokedRoleBitmap = role_bitmap
    self.lastRevokedOldRoles = old_roles
    self.lastRevokedNewRoles = new_roles
    self.lastRevokedUpdatedRoles = new_roles
    self.lastRevokedAccount = account

@external
def callOnlyRoles(resource: uint256, role_bitmap: uint256):
    EAC._check_roles(resource, role_bitmap, msg.sender)

@external
def callOnlyRootRoles(role_bitmap: uint256):
    EAC._check_roles(EAC.ROOT_RESOURCE_VALUE, role_bitmap, msg.sender)

@external
def transferRoles(resource: uint256, src_account: address, dst_account: address):
    EAC._transfer_roles(resource, src_account, dst_account, True)

@external
def revokeAllRoles(resource: uint256, account: address) -> bool:
    return EAC._revoke_roles(resource, roles_lib.ALL_ROLES, account, True)

@external
def revokeAllRolesWithoutCallback(resource: uint256, account: address) -> bool:
    return EAC._revoke_roles(resource, roles_lib.ALL_ROLES, account, False)

@external
def grantRolesWithoutCallback(resource: uint256, role_bitmap: uint256, account: address) -> bool:
    EAC._check_can_grant_roles(resource, role_bitmap, msg.sender)
    if resource == EAC.ROOT_RESOURCE_VALUE:
        raw_revert(method_id("EACRootResourceNotAllowed()"))
    return EAC._grant_roles(resource, role_bitmap, account, False)

@external
def revokeRolesWithoutCallback(resource: uint256, role_bitmap: uint256, account: address) -> bool:
    EAC._check_can_revoke_roles(resource, role_bitmap, msg.sender)
    if resource == EAC.ROOT_RESOURCE_VALUE:
        raw_revert(method_id("EACRootResourceNotAllowed()"))
    return EAC._revoke_roles(resource, role_bitmap, account, False)

@external
def transferRolesWithoutCallback(resource: uint256, src_account: address, dst_account: address):
    EAC._transfer_roles(resource, src_account, dst_account, False)

@external
@view
def supportsInterface(interface_id: bytes4) -> bool:
    return interface_id == 0x8f452d62 or interface_id == 0x01ffc9a7
