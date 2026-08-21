# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

LOWER_HEX: constant(Bytes[16]) = b"0123456789abcdef"
UPPER_HEX: constant(Bytes[16]) = b"0123456789ABCDEF"

@internal
@pure
def _address_nibble(raw: uint256, position: uint256) -> uint256:
    return (raw >> (156 - position * 4)) & 15

@internal
@pure
def _lower_char(raw: uint256, position: uint256) -> Bytes[1]:
    return slice(LOWER_HEX, self._address_nibble(raw, position), 1)

@internal
@pure
def _checksum_char(raw: uint256, hash_value: uint256, position: uint256) -> Bytes[1]:
    nibble: uint256 = self._address_nibble(raw, position)
    hash_nibble: uint256 = (hash_value >> (252 - position * 4)) & 15
    if nibble >= 10 and hash_nibble >= 8:
        return slice(UPPER_HEX, nibble, 1)
    return slice(LOWER_HEX, nibble, 1)

@internal
@pure
def to_address_string(addr: address) -> String[40]:
    raw: uint256 = convert(addr, uint256)
    a: Bytes[10] = concat(self._lower_char(raw, 0), self._lower_char(raw, 1), self._lower_char(raw, 2), self._lower_char(raw, 3), self._lower_char(raw, 4), self._lower_char(raw, 5), self._lower_char(raw, 6), self._lower_char(raw, 7), self._lower_char(raw, 8), self._lower_char(raw, 9))
    b: Bytes[10] = concat(self._lower_char(raw, 10), self._lower_char(raw, 11), self._lower_char(raw, 12), self._lower_char(raw, 13), self._lower_char(raw, 14), self._lower_char(raw, 15), self._lower_char(raw, 16), self._lower_char(raw, 17), self._lower_char(raw, 18), self._lower_char(raw, 19))
    c: Bytes[10] = concat(self._lower_char(raw, 20), self._lower_char(raw, 21), self._lower_char(raw, 22), self._lower_char(raw, 23), self._lower_char(raw, 24), self._lower_char(raw, 25), self._lower_char(raw, 26), self._lower_char(raw, 27), self._lower_char(raw, 28), self._lower_char(raw, 29))
    d: Bytes[10] = concat(self._lower_char(raw, 30), self._lower_char(raw, 31), self._lower_char(raw, 32), self._lower_char(raw, 33), self._lower_char(raw, 34), self._lower_char(raw, 35), self._lower_char(raw, 36), self._lower_char(raw, 37), self._lower_char(raw, 38), self._lower_char(raw, 39))
    return convert(concat(a, b, c, d), String[40])

@internal
@pure
def to_checksum_hex_string(addr: address) -> String[42]:
    raw: uint256 = convert(addr, uint256)
    lower: String[40] = self.to_address_string(addr)
    hash_value: uint256 = convert(keccak256(lower), uint256)
    a: Bytes[10] = concat(self._checksum_char(raw, hash_value, 0), self._checksum_char(raw, hash_value, 1), self._checksum_char(raw, hash_value, 2), self._checksum_char(raw, hash_value, 3), self._checksum_char(raw, hash_value, 4), self._checksum_char(raw, hash_value, 5), self._checksum_char(raw, hash_value, 6), self._checksum_char(raw, hash_value, 7), self._checksum_char(raw, hash_value, 8), self._checksum_char(raw, hash_value, 9))
    b: Bytes[10] = concat(self._checksum_char(raw, hash_value, 10), self._checksum_char(raw, hash_value, 11), self._checksum_char(raw, hash_value, 12), self._checksum_char(raw, hash_value, 13), self._checksum_char(raw, hash_value, 14), self._checksum_char(raw, hash_value, 15), self._checksum_char(raw, hash_value, 16), self._checksum_char(raw, hash_value, 17), self._checksum_char(raw, hash_value, 18), self._checksum_char(raw, hash_value, 19))
    c: Bytes[10] = concat(self._checksum_char(raw, hash_value, 20), self._checksum_char(raw, hash_value, 21), self._checksum_char(raw, hash_value, 22), self._checksum_char(raw, hash_value, 23), self._checksum_char(raw, hash_value, 24), self._checksum_char(raw, hash_value, 25), self._checksum_char(raw, hash_value, 26), self._checksum_char(raw, hash_value, 27), self._checksum_char(raw, hash_value, 28), self._checksum_char(raw, hash_value, 29))
    d: Bytes[10] = concat(self._checksum_char(raw, hash_value, 30), self._checksum_char(raw, hash_value, 31), self._checksum_char(raw, hash_value, 32), self._checksum_char(raw, hash_value, 33), self._checksum_char(raw, hash_value, 34), self._checksum_char(raw, hash_value, 35), self._checksum_char(raw, hash_value, 36), self._checksum_char(raw, hash_value, 37), self._checksum_char(raw, hash_value, 38), self._checksum_char(raw, hash_value, 39))
    return convert(concat(b"0x", a, b, c, d), String[42])

@internal
@pure
def to_string(number: uint256) -> String[78]:
    return uint2str(number)
