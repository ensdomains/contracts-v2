// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

library LibISO8601 {
    /// @dev The timestamp is out of range.
    /// @dev Error selector: `0x09064f83`
    error TimestampOutOfRange(uint256 timestamp);

    function toISO8601(uint256 ts) internal pure returns (string memory result) {
        if (ts >= 253402300800) revert TimestampOutOfRange(ts);

        assembly {
            // Allocate memory
            result := mload(0x40)
            mstore(0x40, add(result, 0x40))
            mstore(result, 20)

            // Variable reuse strategy to avoid stack-too-deep:
            // a: totalDays -> qday -> qjul -> yday -> bump -> month
            // b: secs -> second
            // c: cent -> year
            // d: N -> M -> hour
            // day: keeps day value
            // minute: keeps minute value
            // e: digit extraction helper

            // Split timestamp
            let a := div(ts, 86400)
            let b := sub(ts, mul(a, 86400))

            // Howard Hinnant date algorithm / Ben Joffe fast date algorithm
            // https://howardhinnant.github.io/date_algorithms.html / https://www.benjoffe.com/fast-date
            a := add(a, 719468)
            a := add(shl(2, a), 3)
            let c := div(a, 146097)
            a := add(sub(a, and(c, not(3))), shl(2, c))
            c := div(a, 1461)
            a := shr(2, mod(a, 1461))
            let d := add(mul(a, 2141), 197913)
            let day := add(div(and(d, 0xffff), 2141), 1)
            d := shr(16, d)
            a := gt(a, 305)
            c := add(c, a)
            a := sub(d, mul(a, 12))

            // Time
            d := div(b, 3600)
            b := sub(b, mul(d, 3600))
            let minute := div(b, 60)
            b := sub(b, mul(minute, 60))

            // Year YYYY (extract digits from least to most significant)
            let e := sub(c, mul(div(c, 10), 10))
            mstore8(add(result, 35), add(48, e))
            c := div(c, 10)
            e := sub(c, mul(div(c, 10), 10))
            mstore8(add(result, 34), add(48, e))
            c := div(c, 10)
            e := sub(c, mul(div(c, 10), 10))
            mstore8(add(result, 33), add(48, e))
            mstore8(add(result, 32), add(48, div(c, 10)))
            mstore8(add(result, 36), 0x2d)

            // Month MM (1-12): gt is cheaper than div
            e := gt(a, 9)
            mstore8(add(result, 37), add(48, e))
            mstore8(add(result, 38), add(48, sub(a, mul(e, 10))))
            mstore8(add(result, 39), 0x2d)

            // Day DD (1-31)
            e := div(day, 10)
            mstore8(add(result, 40), add(48, e))
            mstore8(add(result, 41), add(48, sub(day, mul(e, 10))))
            mstore8(add(result, 42), 0x54)

            // Hour HH (0-23)
            e := div(d, 10)
            mstore8(add(result, 43), add(48, e))
            mstore8(add(result, 44), add(48, sub(d, mul(e, 10))))
            mstore8(add(result, 45), 0x3a)

            // Minute MM (0-59)
            e := div(minute, 10)
            mstore8(add(result, 46), add(48, e))
            mstore8(add(result, 47), add(48, sub(minute, mul(e, 10))))
            mstore8(add(result, 48), 0x3a)

            // Second SS (0-59)
            e := div(b, 10)
            mstore8(add(result, 49), add(48, e))
            mstore8(add(result, 50), add(48, sub(b, mul(e, 10))))
            mstore8(add(result, 51), 0x5a)
        }
    }
}
