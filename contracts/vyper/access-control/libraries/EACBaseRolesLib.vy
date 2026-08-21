# pragma version ~=0.4.3
# SPDX-License-Identifier: MIT

ALL_ROLES: constant(uint256) = 0x1111111111111111111111111111111111111111111111111111111111111111
ADMIN_ROLES: constant(uint256) = 0x1111111111111111111111111111111100000000000000000000000000000000
_NYBBLE_LSB: constant(uint256) = 0x1111111111111111111111111111111111111111111111111111111111111111
_NYBBLE_MSB: constant(uint256) = 0x8888888888888888888888888888888888888888888888888888888888888888

@internal
@pure
def with_admin_roles_applied(role_bitmap: uint256) -> uint256:
    admins: uint256 = role_bitmap >> 128
    return (admins << 128) | admins

@internal
@pure
def from_counts(counts: uint256) -> uint256:
    return (counts | (counts >> 1) | (counts >> 2) | (counts >> 3)) & ALL_ROLES

@internal
@pure
def has_zero_nybbles(value: uint256) -> bool:
    # Solidity performs this subtraction in an unchecked block.
    zero_nybbles: uint256 = unsafe_sub(value, _NYBBLE_LSB) & ~value & _NYBBLE_MSB
    return zero_nybbles != 0
