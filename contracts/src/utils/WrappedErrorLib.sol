// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {HexUtils} from "@ens/contracts/utils/HexUtils.sol";

/// @dev Library to wrap and unwrap typed error data inside of `Error(string)`.
///      Uses hex to embed arbitrary data and avoid invalid unicode.
library WrappedErrorLib {
    /// @dev Error selector for `Error(string)`.
    bytes4 public constant ERROR_STRING_SELECTOR = 0x08c379a0;

    /// @dev The detectable human-readable error prefix.
    bytes16 public constant WRAPPED_ERROR_PREFIX = "WrappedError:0x";
    // Alternative: unicode"❌WrappedErr:0x";
    // Alternative: unicode"❌WrappedError:";

    /// @dev Wrap an error and then revert.
    function wrapAndRevert(bytes memory err) internal pure {
        err = wrap(err);
        assembly {
            revert(add(err, 32), mload(err))
        }
    }

    /// @dev Embed a typed error into `Error(string)`.
    ///      Does nothing if already `Error(string)`.
    ///      For detection, `WRAPPED_ERROR_PREFIX` is leading bytes the error string.
    function wrap(bytes memory err) internal pure returns (bytes memory) {
        if (err.length > 0 && bytes4(err) != ERROR_STRING_SELECTOR) {
            // assert((err.length & 31) == 4);
            err = abi.encodeWithSelector(
                ERROR_STRING_SELECTOR,
                abi.encodePacked(WRAPPED_ERROR_PREFIX, HexUtils.bytesToHex(err))
            );
        }
        return err;
    }

    /// @dev Unwrap a typed error from `Error(string)`.
    ///      Does nothing if detection and extracton fails.
    ///
    /// @param err The error data to unwrap.
    ///
    /// @return The unwrapped error data, or unmodified if not wrapped.
    function unwrap(bytes memory err) internal pure returns (bytes memory) {
        if (bytes4(err) == ERROR_STRING_SELECTOR) {
            bytes memory v;
            assembly {
                v := add(err, 4) // skip selector
            }
            v = abi.decode(v, (bytes));
            if (bytes16(v) == WRAPPED_ERROR_PREFIX) {
                (bytes memory inner, bool ok) = HexUtils.hexToBytes(v, 16, v.length);
                if (ok) {
                    return inner;
                }
            }
        }
        return err;
    }
}
