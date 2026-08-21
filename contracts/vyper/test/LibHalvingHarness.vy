# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

from ..registrar.libraries import LibHalving as lib

@external
@pure
def halving(initial: uint256, half: uint256, elapsed: uint256) -> uint256:
    return lib.halving(initial, half, elapsed)
