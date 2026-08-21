# pragma version ~=0.4.3
# SPDX-License-Identifier: MIT

@internal
@pure
def id(label: String[255]) -> uint256:
    return convert(keccak256(label), uint256)

@internal
@pure
def with_version(any_id: uint256, version_id: uint32) -> uint256:
    return any_id ^ (any_id & 0xffffffff) ^ convert(version_id, uint256)
