# pragma version ==0.5.0a3
# SPDX-License-Identifier: MIT

PRECISION: constant(uint256) = 1000000000000000000
BIT1: constant(uint256) = 999989423469314432
BIT2: constant(uint256) = 999978847050491904
BIT3: constant(uint256) = 999957694548431104
BIT4: constant(uint256) = 999915390886613504
BIT5: constant(uint256) = 999830788931929088
BIT6: constant(uint256) = 999661606496243712
BIT7: constant(uint256) = 999323327502650752
BIT8: constant(uint256) = 998647112890970240
BIT9: constant(uint256) = 997296056085470080
BIT10: constant(uint256) = 994599423483633152
BIT11: constant(uint256) = 989228013193975424
BIT12: constant(uint256) = 978572062087700096
BIT13: constant(uint256) = 957603280698573696
BIT14: constant(uint256) = 917004043204671232
BIT15: constant(uint256) = 840896415253714560
BIT16: constant(uint256) = 707106781186547584

@internal
@pure
def _add_fraction(amount: uint256, fraction: uint256) -> uint256:
    result: uint256 = amount
    if fraction & (1 << 0) != 0: result = result * BIT1 // PRECISION
    if fraction & (1 << 1) != 0: result = result * BIT2 // PRECISION
    if fraction & (1 << 2) != 0: result = result * BIT3 // PRECISION
    if fraction & (1 << 3) != 0: result = result * BIT4 // PRECISION
    if fraction & (1 << 4) != 0: result = result * BIT5 // PRECISION
    if fraction & (1 << 5) != 0: result = result * BIT6 // PRECISION
    if fraction & (1 << 6) != 0: result = result * BIT7 // PRECISION
    if fraction & (1 << 7) != 0: result = result * BIT8 // PRECISION
    if fraction & (1 << 8) != 0: result = result * BIT9 // PRECISION
    if fraction & (1 << 9) != 0: result = result * BIT10 // PRECISION
    if fraction & (1 << 10) != 0: result = result * BIT11 // PRECISION
    if fraction & (1 << 11) != 0: result = result * BIT12 // PRECISION
    if fraction & (1 << 12) != 0: result = result * BIT13 // PRECISION
    if fraction & (1 << 13) != 0: result = result * BIT14 // PRECISION
    if fraction & (1 << 14) != 0: result = result * BIT15 // PRECISION
    if fraction & (1 << 15) != 0: result = result * BIT16 // PRECISION
    return result

@internal
@pure
def halving(initial: uint256, half: uint256, elapsed: uint256) -> uint256:
    if initial == 0 or half == 0:
        return 0
    if elapsed == 0:
        return initial
    x: uint256 = (elapsed * PRECISION) // half
    integer_part: uint256 = x // PRECISION
    fractional_part: uint256 = x - integer_part * PRECISION
    shifted: uint256 = 0
    if integer_part < 256:
        shifted = initial >> integer_part
    return self._add_fraction(shifted, (fractional_part << 16) // PRECISION)
