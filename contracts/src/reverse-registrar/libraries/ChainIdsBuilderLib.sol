// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @title ChainIdsBuilderLib
/// @notice Validates a strictly-ascending array of chain IDs and builds the
///         comma-separated display string in a single pass with O(n) memory.
/// @dev The naive `string.concat` approach allocates a new copy of the
///      accumulated string on every iteration, resulting in O(n²) total memory.
///      This library pre-allocates a single buffer and writes each chain ID's
///      decimal representation directly into it, keeping memory O(n).
library ChainIdsBuilderLib {
    /// @notice Thrown when the chain ID array is not in strictly ascending order.
    /// @dev Error selector: `0xea0b14e2`
    error ChainIdsNotAscending();

    /// @notice Thrown when the current chain ID is not included in the array.
    /// @dev Error selector: `0x756925c8`
    error CurrentChainNotFound(uint256 chainId);

    /// @notice Validates chain IDs are strictly ascending, contain `currentChainId`,
    ///         and builds the comma-separated display string.
    /// @param chainIds       Calldata array of chain IDs (must be strictly ascending).
    /// @param currentChainId The chain ID that must be present in the array.
    /// @return result The comma-separated string, e.g. "1, 10, 8453".
    function validateAndBuild(
        uint256[] calldata chainIds,
        uint256 currentChainId
    ) internal pure returns (string memory result) {
        uint256 length = chainIds.length;
        if (length == 0) revert CurrentChainNotFound(currentChainId);

        /// @solidity memory-safe-assembly
        assembly {
            // Grab the free memory pointer; the string will be built in-place.
            result := mload(0x40)
            let buf := add(result, 32) // data region starts after the 32-byte length slot
            let ptr := buf // write cursor
            let prev := 0
            let containsCurrent := 0

            for {
                let i := 0
            } lt(i, length) {
                i := add(i, 1)
            } {
                let val := calldataload(add(chainIds.offset, shl(5, i)))

                // --- Validate strictly ascending (skip for the first element) ---
                if i {
                    if iszero(gt(val, prev)) {
                        // revert ChainIdsNotAscending()
                        mstore(
                            0x00,
                            0xea0b14e200000000000000000000000000000000000000000000000000000000
                        )
                        revert(0x00, 0x04)
                    }
                }
                prev := val
                // --- Track whether the required chain ID is present ---
                if eq(val, currentChainId) {
                    containsCurrent := 1
                }

                // --- Write ", " separator before every element except the first ---
                if i {
                    mstore8(ptr, 0x2c) // ','
                    ptr := add(ptr, 1)
                    mstore8(ptr, 0x20) // ' '
                    ptr := add(ptr, 1)
                }

                // --- Write the decimal representation of `val` ---
                switch val
                case 0 {
                    mstore8(ptr, 0x30) // '0'
                    ptr := add(ptr, 1)
                }
                default {
                    // Count decimal digits
                    let digits := 0
                    let tmp := val
                    for {} tmp {} {
                        digits := add(digits, 1)
                        tmp := div(tmp, 10)
                    }

                    // Write digits right-to-left into the buffer
                    let end := add(ptr, digits)
                    tmp := val
                    for {} tmp {} {
                        end := sub(end, 1)
                        mstore8(end, add(48, mod(tmp, 10)))
                        tmp := div(tmp, 10)
                    }
                    ptr := add(ptr, digits)
                }
            }

            // Store the final string length and update the free memory pointer.
            mstore(result, sub(ptr, buf))
            mstore(0x40, and(add(ptr, 31), not(31)))

            // Revert if the required chain ID was never encountered.
            if iszero(containsCurrent) {
                // revert CurrentChainNotFound(currentChainId)
                mstore(0x00, 0x756925c800000000000000000000000000000000000000000000000000000000)
                mstore(0x04, currentChainId)
                revert(0x00, 0x24)
            }
        }
    }
}
