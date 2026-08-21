# pragma version ==0.5.0a3
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

ROLE_APPROVE: constant(uint256) = 1
ROLE_APPROVE_ADMIN: constant(uint256) = ROLE_APPROVE << 128
ROLE_CAN_NAME: constant(uint256) = 1 << 4
ROLE_CAN_NAME_ADMIN: constant(uint256) = ROLE_CAN_NAME << 128
DEFAULT_ROLE_BITMAP: constant(uint256) = ROLE_APPROVE | ROLE_APPROVE_ADMIN | ROLE_CAN_NAME | ROLE_CAN_NAME_ADMIN
_approved: HashMap[address, bool]

event ApprovalChanged:
    addr: indexed(address)
    approved: bool
    sender: indexed(address)

@deploy
def __init__(root_account: address):
    EAC._grant_roles(EAC.ROOT_RESOURCE_VALUE, DEFAULT_ROLE_BITMAP, root_account, False)

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
    return interface_id == 0x3d140d21 or interface_id == 0x1aedefda or interface_id == convert(method_id("isContractNamer(address)"), bytes4) or interface_id == 0x8f452d62 or interface_id == 0x01ffc9a7

@external
def approve(addr: address, approved: bool):
    EAC._check_roles(EAC.ROOT_RESOURCE_VALUE, ROLE_APPROVE, msg.sender)
    assert self._approved[addr] != approved
    self._approved[addr] = approved
    log ApprovalChanged(addr=addr, approved=approved, sender=msg.sender)

@external
@view
def includes(addr: address) -> bool:
    return self._approved[addr]

@external
@view
def isContractNamer(namer: address) -> bool:
    return EAC._stored_roles(EAC.ROOT_RESOURCE_VALUE, namer) & ROLE_CAN_NAME == ROLE_CAN_NAME
