//SPDX-License-Identifier: MIT
pragma solidity >=0.8.25;

// solhint-disable no-inline-assembly

/// @dev Low-level memory helpers for copying, pointer conversion, and word loading.
library LibMem {
    /// @dev If true, LibMem uses mcopy.
    bool internal constant REMAPPED = true;

    /// @dev Copy `mem[src:src+len]` to `mem[dst:dst+len]`.
    /// @param src The source memory offset.
    /// @param dst The destination memory offset.
    /// @param len The number of bytes to copy.
    function copy(uint256 dst, uint256 src, uint256 len) internal pure {
        assembly {
            mcopy(dst, src, len)
        }
    }

    /// @dev Convert bytes to a memory offset.
    /// @param v The bytes to convert.
    /// @return ret The corresponding memory offset.
    function ptr(bytes memory v) internal pure returns (uint256 ret) {
        assembly {
            ret := add(v, 32)
        }
    }

    /// @dev Read word at memory offset.
    /// @param src The memory offset.
    /// @return ret The read word.
    function load(uint256 src) internal pure returns (uint256 ret) {
        assembly {
            ret := mload(src)
        }
    }
}
