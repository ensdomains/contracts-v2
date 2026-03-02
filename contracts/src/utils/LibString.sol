// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title LibString
/// @notice Gas-efficient string conversion utilities for Ethereum addresses and numbers.
/// @dev All functions use inline assembly for optimal gas efficiency.
library LibString {
    ////////////////////////////////////////////////////////////////////////
    // Address to String Conversions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Converts an address to its lowercase hex string representation (without 0x prefix).
    /// @dev Uses inline assembly for gas efficiency. Produces exactly 40 hex characters.
    /// @param value The address to convert.
    /// @return result The lowercase hex string (40 bytes, no 0x prefix).
    function toAddressString(address value) internal pure returns (string memory result) {
        /// @solidity memory-safe-assembly
        assembly {
            // Allocate memory for result string
            result := mload(0x40)
            mstore(0x40, add(result, 0x60)) // 32 (length slot) + 40 (data) padded to 64 bytes
            mstore(result, 40) // Store string length (40 hex chars)

            // Hex lookup table: "0123456789abcdef" left-aligned in a bytes32
            let table := 0x3031323334353637383961626364656600000000000000000000000000000000

            let o := add(result, 32) // Pointer to string data (after length slot)
            let v := shl(96, value) // Left-align 160-bit address in 256-bit word

            // Process 1 byte (2 nibbles) per iteration → 20 iterations for 40 hex chars
            for {
                let i := 0
            } lt(i, 20) {
                i := add(i, 1)
            } {
                let b := byte(i, v) // Extract i-th byte from left
                let pos := shl(1, i) // Output position = i * 2
                mstore8(add(o, pos), byte(shr(4, b), table)) // High nibble → ASCII
                mstore8(add(o, add(pos, 1)), byte(and(b, 0xf), table)) // Low nibble → ASCII
            }
        }
    }

    /// @notice Converts an address to its EIP-55 checksummed hex string.
    /// @dev Uses toAddressString for lowercase conversion, then applies EIP-55 checksum.
    ///      Produces "0x" + 40 hex characters.
    /// @param addr The address to convert.
    /// @return result The checksummed hex string (42 bytes).
    function toChecksumHexString(address addr) internal pure returns (string memory result) {
        // Get lowercase hex without prefix (40 chars)
        string memory lowercase = toAddressString(addr);

        assembly {
            result := mload(0x40)
            mstore(0x40, add(result, 0x60)) // 32 (length) + 42 (data) = 74, round up to 96
            mstore(result, 42) // Set string length

            let ptr := add(result, 32)
            // Write "0x" prefix
            mstore8(ptr, 0x30) // '0'
            mstore8(add(ptr, 1), 0x78) // 'x'

            let hexPtr := add(ptr, 2)
            let srcPtr := add(lowercase, 32)

            // Copy 40 bytes from lowercase string to result
            mstore(hexPtr, mload(srcPtr))
            mstore(add(hexPtr, 32), mload(add(srcPtr, 32)))

            // Hash the 40 lowercase hex chars for checksum
            let hashVal := keccak256(hexPtr, 40)

            // Apply checksum: uppercase letters where hash nibble >= 8
            for {
                let i := 0
            } lt(i, 40) {
                i := add(i, 1)
            } {
                let charPos := add(hexPtr, i)
                let char := byte(0, mload(charPos))
                // If char is a-f (97-102) and hash nibble >= 8, uppercase it (xor with 0x20)
                // Hash nibble at position i: shift right by (252 - i*4) and mask
                if and(gt(char, 96), gt(and(shr(sub(252, shl(2, i)), hashVal), 0xf), 7)) {
                    mstore8(charPos, xor(char, 0x20))
                }
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Number to String Conversions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Converts a uint256 to its ASCII decimal string representation.
    /// @param value The value to convert.
    /// @return result The decimal string.
    function toString(uint256 value) internal pure returns (string memory result) {
        assembly {
            result := mload(0x40)

            switch value
            case 0 {
                mstore(0x40, add(result, 0x40)) // 32 (length slot) + 1 (data) = 33, round to 64
                mstore(result, 1) // length = 1
                mstore8(add(result, 32), 0x30) // '0'
            }
            default {
                // Count digits: `for {} temp {}` is Yul idiom for `while (temp != 0)`
                let temp := value
                let digits := 0
                for {} temp {} {
                    digits := add(digits, 1)
                    temp := div(temp, 10)
                }

                // Set length and update free memory pointer (rounded to 32-byte boundary)
                mstore(result, digits)
                mstore(0x40, add(result, and(add(add(32, digits), 31), not(31))))

                // Write digits from right to left: `for {} temp {}` is Yul idiom for `while (temp != 0)`
                let ptr := add(add(result, 32), digits)
                temp := value
                for {} temp {} {
                    ptr := sub(ptr, 1)
                    mstore8(ptr, add(48, mod(temp, 10))) // 48 = ASCII '0'
                    temp := div(temp, 10)
                }
            }
        }
    }
}
