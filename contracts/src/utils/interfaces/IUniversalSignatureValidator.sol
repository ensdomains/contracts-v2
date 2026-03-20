// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @dev Interface selector: `0x98ef1ed8`
interface IUniversalSignatureValidator {
    /// @notice Validates a signature.
    /// @param signer The signer of the signature.
    /// @param hash The hash of the message that was signed.
    /// @param signature The signature to validate.
    /// @return isValid Whether the signature is valid.
    function isValidSig(
        address signer,
        bytes32 hash,
        bytes calldata signature
    ) external returns (bool);
}
