// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Computes exponential decay `initial / 2^(elapsed / half)` using fixed-point arithmetic
///      with 18-decimal precision. The elapsed/half ratio is decomposed into integer and fractional
///      parts: the integer part is applied via right-shift, the fractional part via multiplication
///      with precomputed constants.
library LibHalving {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Fixed-point scale factor (10^18).
    uint256 private constant PRECISION = 1e18;

    /// @dev Precomputed values of `0.5^(2^k / 65536) * 10^18` for the corresponding power-of-two
    ///      bit position. Together they compose any fractional power of 0.5 in 16-bit resolution
    ///      via binary decomposition.
    uint256 private constant BIT1 = 999989423469314432; // 0.5 ^ 1/65536 * (10 ** 18)
    uint256 private constant BIT2 = 999978847050491904; // 0.5 ^ 2/65536 * (10 ** 18)
    uint256 private constant BIT3 = 999957694548431104;
    uint256 private constant BIT4 = 999915390886613504;
    uint256 private constant BIT5 = 999830788931929088;
    uint256 private constant BIT6 = 999661606496243712;
    uint256 private constant BIT7 = 999323327502650752;
    uint256 private constant BIT8 = 998647112890970240;
    uint256 private constant BIT9 = 997296056085470080;
    uint256 private constant BIT10 = 994599423483633152;
    uint256 private constant BIT11 = 989228013193975424;
    uint256 private constant BIT12 = 978572062087700096;
    uint256 private constant BIT13 = 957603280698573696;
    uint256 private constant BIT14 = 917004043204671232;
    uint256 private constant BIT15 = 840896415253714560;
    uint256 private constant BIT16 = 707106781186547584;

    ////////////////////////////////////////////////////////////////////////
    // Library Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Compute `initial / 2 ** (elapsed / half)`.
    /// @param initial The initial value.
    /// @param half The halving period.
    /// @param elapsed The elapsed duration.
    function halving(
        uint256 initial,
        uint256 half,
        uint256 elapsed
    ) internal pure returns (uint256) {
        if (initial == 0 || half == 0) return 0;
        if (elapsed == 0) return initial;
        uint256 x = (elapsed * PRECISION) / half;
        uint256 i = x / PRECISION;
        uint256 f = x - i * PRECISION;
        return _addFraction(initial >> i, (f << 16) / PRECISION);
    }

    /// @dev Applies the fractional part of the exponent by multiplying `x` with each precomputed
    ///      constant whose corresponding bit is set in the 16-bit fraction, implementing
    ///      `x * 0.5^(fraction / 65536)`.
    function _addFraction(uint256 x, uint256 fraction) private pure returns (uint256) {
        if (fraction & (1 << 0) != 0) {
            x = (x * BIT1) / PRECISION;
        }
        if (fraction & (1 << 1) != 0) {
            x = (x * BIT2) / PRECISION;
        }
        if (fraction & (1 << 2) != 0) {
            x = (x * BIT3) / PRECISION;
        }
        if (fraction & (1 << 3) != 0) {
            x = (x * BIT4) / PRECISION;
        }
        if (fraction & (1 << 4) != 0) {
            x = (x * BIT5) / PRECISION;
        }
        if (fraction & (1 << 5) != 0) {
            x = (x * BIT6) / PRECISION;
        }
        if (fraction & (1 << 6) != 0) {
            x = (x * BIT7) / PRECISION;
        }
        if (fraction & (1 << 7) != 0) {
            x = (x * BIT8) / PRECISION;
        }
        if (fraction & (1 << 8) != 0) {
            x = (x * BIT9) / PRECISION;
        }
        if (fraction & (1 << 9) != 0) {
            x = (x * BIT10) / PRECISION;
        }
        if (fraction & (1 << 10) != 0) {
            x = (x * BIT11) / PRECISION;
        }
        if (fraction & (1 << 11) != 0) {
            x = (x * BIT12) / PRECISION;
        }
        if (fraction & (1 << 12) != 0) {
            x = (x * BIT13) / PRECISION;
        }
        if (fraction & (1 << 13) != 0) {
            x = (x * BIT14) / PRECISION;
        }
        if (fraction & (1 << 14) != 0) {
            x = (x * BIT15) / PRECISION;
        }
        if (fraction & (1 << 15) != 0) {
            x = (x * BIT16) / PRECISION;
        }
        return x;
    }
}
