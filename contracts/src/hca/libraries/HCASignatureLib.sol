// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title HCA Signature Library
/// @notice Validates EOA and wallet-defined signatures for the HCA integrations.
/// @dev Keeps canonical ECDSA recovery separate from opaque ERC-1271 wallet signatures.
library HCASignatureLib {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Length of one ECDSA signature.
    uint256 internal constant SIGNATURE_LENGTH = 65;

    /// @dev Highest canonical secp256k1 `s` value accepted by EIP-2.
    uint256 private constant _HALF_CURVE_ORDER =
        0x7FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF5D576E7357A4501DDFE92F46681B20A0;

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Validates an opaque owner signature using the owner's ERC-1271 implementation.
    /// @dev Uses a static call and requires the standard ABI-encoded success value.
    /// @param owner The owner address, including an EOA executing delegated wallet code.
    /// @param digest The exact authorization digest expected by the protocol.
    /// @param signature Opaque wallet-specific signature bytes.
    /// @return valid Whether the owner returned the ERC-1271 success value.
    function isValidContractSignature(address owner, bytes32 digest, bytes memory signature)
        internal
        view
        returns (bool)
    {
        return SignatureChecker.isValidERC1271SignatureNow(owner, digest, signature);
    }

    /// @notice Validates a tagged ABI envelope containing an opaque contract-owner signature.
    /// @dev The envelope is abi.encode(bytes1(0x06), signature), distinct from legacy 65-byte signatures.
    /// @param owner The owner address, including an EOA executing delegated wallet code.
    /// @param digest The exact authorization digest expected by the protocol.
    /// @param envelope A tagged ABI-encoded contract signature.
    /// @return valid Whether decoding and ERC-1271 validation succeeded.
    function isValidContractEnvelope(address owner, bytes32 digest, bytes calldata envelope)
        internal
        view
        returns (bool)
    {
        if (
            envelope.length < 96 ||
            bytes32(envelope[:32]) != bytes32(bytes1(0x06)) ||
            uint256(bytes32(envelope[32:64])) != 64
        )
            return false;
        uint256 length = uint256(bytes32(envelope[64:96]));
        if (length > envelope.length - 96 || envelope.length != 96 + ((length + 31) & ~uint256(31)))
            return false;
        return isValidContractSignature(owner, digest, envelope[96:96 + length]);
    }

    /// @notice Decodes a length-prefixed contract signature while preserving required trailing data.
    /// @dev Rejects signatures that consume the required tail or leave no operation data.
    /// @param data The complete validator envelope.
    /// @param offset Offset of the two-byte signature length.
    /// @param tailLength Required bytes after the signature, excluding the nonempty operation.
    /// @return signature The bounded signature slice.
    /// @return end Its ending offset, or zero when the envelope is invalid.
    function decodeContractSignature(bytes calldata data, uint256 offset, uint256 tailLength)
        internal
        pure
        returns (bytes calldata signature, uint256 end)
    {
        signature = data[0:0];
        if (offset + 2 > data.length)
            return (signature, 0);
        uint256 length = uint16(bytes2(data[offset:offset + 2]));
        offset += 2;
        end = offset + length;
        if (end + tailLength >= data.length)
            return (signature, 0);
        signature = data[offset:end];
    }

    /// @notice Recovers a signer from a Rhinestone-compatible signature.
    /// @dev Values 31 and 32 select EIP-191 wrapping. Values 0, 1, 27, and 28 recover the supplied
    ///      digest directly. Invalid signatures return the zero address.
    /// @param digest The digest represented by the signature.
    /// @param signature The compact ECDSA signature.
    /// @return signer The recovered signer or the zero address.
    function recover(bytes32 digest, bytes calldata signature)
        internal
        pure
        returns (address signer)
    {
        if (signature.length != SIGNATURE_LENGTH) {
            return address(0);
        }

        (bytes32 r, bytes32 s, uint8 v) = rsvFromSignature(signature);
        return recover(digest, r, s, v);
    }

    /// @notice Recovers a signer from separate Rhinestone-compatible signature fields.
    /// @dev Normalizes compact recovery identifiers and rejects non-canonical `s` values.
    /// @param digest The digest represented by the signature.
    /// @param r The ECDSA `r` value.
    /// @param s The ECDSA `s` value.
    /// @param v The recovery identifier and optional EIP-191 mode marker.
    /// @return signer The recovered signer or the zero address.
    function recover(bytes32 digest, bytes32 r, bytes32 s, uint8 v)
        internal
        pure
        returns (address signer)
    {
        if (v == 31 || v == 32) {
            digest = MessageHashUtils.toEthSignedMessageHash(digest);
            v -= 4;
        } else if (v < 27) {
            v += 27;
        }
        if (v != 27 && v != 28) {
            return address(0);
        }
        if (uint256(s) > _HALF_CURVE_ORDER) {
            return address(0);
        }
        return ecrecover(digest, v, r, s);
    }

    /// @notice Checks the raw and EIP-191 UserOperation signatures accepted by the Nexus validator.
    /// @dev Tries the raw digest first unless the signature explicitly selects EIP-191 wrapping.
    /// @param expectedSigner The account owner expected to have signed the digest.
    /// @param digest The EntryPoint UserOperation digest.
    /// @param signature The ECDSA signature to validate.
    /// @return valid Whether the signature is valid for `expectedSigner`.
    function isValidUserOpSignature(address expectedSigner, bytes32 digest, bytes calldata signature)
        internal
        pure
        returns (bool valid)
    {
        if (signature.length != SIGNATURE_LENGTH) {
            return false;
        }

        (bytes32 r, bytes32 s, uint8 v) = rsvFromSignature(signature);

        bool explicitEthSigned = v == 31 || v == 32;
        if (explicitEthSigned) {
            v -= 4;
        } else if (v < 27) {
            v += 27;
        }
        if (v != 27 && v != 28) {
            return false;
        }
        if (uint256(s) > _HALF_CURVE_ORDER) {
            return false;
        }

        address signer;
        if (!explicitEthSigned) {
            signer = ecrecover(digest, v, r, s);
            if (signer != address(0) && signer == expectedSigner) {
                return true;
            }
        }

        signer = ecrecover(MessageHashUtils.toEthSignedMessageHash(digest), v, r, s);
        return signer != address(0) && signer == expectedSigner;
    }

    /// @notice Reads the ECDSA fields from a complete signature.
    /// @dev The caller must verify that the signature has the expected length.
    /// @param signature The ECDSA signature to read.
    /// @return r The ECDSA r value.
    /// @return s The ECDSA s value.
    /// @return v The recovery identifier.
    function rsvFromSignature(bytes calldata signature)
        private
        pure
        returns (bytes32 r, bytes32 s, uint8 v)
    {
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
    }
}
