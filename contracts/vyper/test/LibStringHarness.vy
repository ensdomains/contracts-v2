# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

from ..utils import LibString as lib

@external
@pure
def toAddressString(addr: address) -> String[40]:
    return lib.to_address_string(addr)

@external
@pure
def toChecksumHexString(addr: address) -> String[42]:
    return lib.to_checksum_hex_string(addr)

@external
@pure
def toString(number: uint256) -> String[78]:
    return lib.to_string(number)
