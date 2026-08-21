# pragma version ~=0.4.3
# SPDX-License-Identifier: MIT

from ..access_control import EnhancedAccessControl as EAC

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
    pass

@override(EAC)
def _on_roles_revoked(resource: uint256, account: address, old_roles: uint256, new_roles: uint256, role_bitmap: uint256):
    pass

@external
@view
def supportsInterface(interface_id: bytes4) -> bool:
    return interface_id == 0x8f452d62 or interface_id == 0x01ffc9a7
