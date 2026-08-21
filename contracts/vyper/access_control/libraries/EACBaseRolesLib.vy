# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

ALL_ROLES: constant(uint256) = 7719472615821079694904732333912527190217998977709370935963838933860875309329
ADMIN_ROLES: constant(uint256) = 7719472615821079694904732333912527190195313486581308371732947293365424095232
_NYBBLE_LSB: constant(uint256) = 7719472615821079694904732333912527190217998977709370935963838933860875309329
_NYBBLE_MSB: constant(uint256) = 61755780926568637559237858671300217521743991821674967487710711470887002474632

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
def has_zero_nybbles(word: uint256) -> bool:
    zero_nybbles: uint256 = unsafe_sub(word, _NYBBLE_LSB) & ~word & _NYBBLE_MSB
    return zero_nybbles != 0
