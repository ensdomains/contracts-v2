# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

from ..utils import LibLabel as lib

@external
@pure
def id(label: String[1024]) -> uint256:
    return convert(keccak256(label), uint256)

@external
@pure
def withVersion(any_id: uint256, version_id: uint32) -> uint256:
    return lib.with_version(any_id, version_id)
