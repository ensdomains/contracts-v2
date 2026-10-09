// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {HCAOperationHashLib} from "~src/hca/libraries/HCAOperationHashLib.sol";

/// @title HCA Operation Decoder Entry Harness
/// @notice Exposes the exact production internal decoder without changing its memory or hashing logic.
/// @dev This is a library-entry proof boundary, separate from the complete public validator suites.
contract OwnerSessionOperationHarness {
    /// @notice Calls the unmodified assembly decoder and returns its decoded operation and hash.
    function decodeAndHash(bytes calldata data)
        external
        pure
        returns (HCAOperationHashLib.DecodedOperation memory operation, bytes32 operationHash)
    {
        return HCAOperationHashLib.decodeAndHash(data);
    }
}
