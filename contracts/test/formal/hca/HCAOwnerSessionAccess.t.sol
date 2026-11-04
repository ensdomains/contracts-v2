// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {
    MODULE_TYPE_VALIDATOR,
    VALIDATION_FAILED,
    VALIDATION_SUCCESS
} from "nexus/types/Constants.sol";

import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";

import {MockStandaloneHCA} from "../../mocks/MockStandaloneHCAStack.sol";

import {OwnerSessionFixture} from "./owner/OwnerSessionFixture.sol";

/// @title HCA Owner Validator Access Proofs
/// @notice Checks executor access, canonical owner signatures, and ERC-4337 sender binding.
/// @dev Exercises the exact production public entry points. Digests, recovery identifiers, and
///      selected request fields are symbolic; signing/recovery use Halmos's cryptographic model.
///      The owner is supplied by the existing account-interface mock. Each check uses one call,
///      except the stateless module check, which checks installation and uninstallation together.
contract HCAOwnerSessionAccess is OwnerSessionFixture {
    /// @notice Only the configured executor may present even a valid owner signature.
    function check_erc1271ExecutorGate(address sender, bytes32 digest) public {
        vm.assume(sender != INTENT_EXECUTOR);
        bytes memory signature = _sign(OWNER_KEY, digest);
        vm.prank(address(account));
        (bool success, bytes memory result) =
            address(validator).staticcall(
                abi.encodeCall(
                    HCAOwnerAndSessionValidator.isValidSignatureWithSender,
                    (sender, digest, signature)
                )
            );
        assert(!success);
        assert(result.length == 4);
        assert(bytes4(result) == HCAOwnerAndSessionValidator.CallerNotIntentExecutor.selector);
    }

    /// @notice A canonical raw-digest owner signature is accepted for every digest.
    function check_ownerRawSignature(bytes32 digest) public {
        _accept(Envelope(digest, _sign(OWNER_KEY, digest)));
    }

    /// @notice Compact recovery identifiers preserve owner authorization.
    function check_ownerCompactRecoveryId(bytes32 digest) public {
        bytes memory signature = _sign(OWNER_KEY, digest);
        signature[signature.length - 1] = bytes1(uint8(signature[signature.length - 1]) - 27);
        _accept(Envelope(digest, signature));
    }

    /// @notice Explicit EIP-191 recovery identifiers authorize the wrapped owner digest.
    function check_ownerExplicitPersonalSign(bytes32 digest) public {
        bytes memory signature = _sign(OWNER_KEY, MessageHashUtils.toEthSignedMessageHash(digest));
        signature[signature.length - 1] = bytes1(uint8(signature[signature.length - 1]) + 4);
        _accept(Envelope(digest, signature));
    }

    /// @notice A canonical signature from a different modeled key cannot authorize the account.
    function check_ownerWrongSigner(bytes32 digest) public {
        _reject(
            Envelope(digest, _sign(OTHER_KEY, digest)),
            HCAOwnerAndSessionValidator.InvalidSigner.selector
        );
    }

    /// @notice A session key cannot use the unrestricted owner-signature path.
    function check_sessionKeyCannotImpersonateOwner(bytes32 digest) public {
        _reject(
            Envelope(digest, _sign(SESSION_KEY, digest)),
            HCAOwnerAndSessionValidator.InvalidSigner.selector
        );
    }

    /// @notice Every scalar above the canonical half-order threshold is rejected before ECDSA recovery.
    function check_ownerHighSGuard(bytes32 digest, bytes32 r, uint256 highS, bool parity) public {
        vm.assume(highS > SECP256K1_ORDER / 2);
        bytes memory signature = abi.encodePacked(r, bytes32(highS), uint8(parity ? 28 : 27));
        _reject(Envelope(digest, signature), HCAOwnerAndSessionValidator.InvalidSigner.selector);
    }

    /// @notice Every unsupported recovery identifier is rejected independently of recovery behavior.
    function check_ownerRecoveryIdGuard(bytes32 digest, bytes32 r, bytes32 s, uint8 v) public {
        vm.assume(v != 0 && v != 1 && v != 27 && v != 28 && v != 31 && v != 32);
        _reject(
            Envelope(digest, abi.encodePacked(r, s, v)),
            HCAOwnerAndSessionValidator.InvalidSigner.selector
        );
    }

    /// @notice Unsupported envelope modes fail before any session authorization is attempted.
    function check_sessionModeGuard(bytes1 mode, bytes32 data, bytes32 digest) public {
        vm.assume(mode != codec.refundMode());
        vm.assume(mode != codec.permit2Mode());
        _reject(
            Envelope(digest, abi.encodePacked(mode, data)),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice Empty signatures cannot become an owner or session authorization.
    function check_emptySignature(bytes32 digest) public {
        _reject(Envelope(digest, bytes("")), HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice An account reporting no owner cannot authorize an otherwise canonical owner signature.
    function check_zeroOwnerFailsClosed(bytes32 digest) public {
        MockStandaloneHCA emptyAccount = new MockStandaloneHCA(address(0));
        bytes memory signature = _sign(OWNER_KEY, digest);
        vm.prank(address(emptyAccount));
        (bool success, bytes memory result) =
            address(validator).staticcall(
                abi.encodeCall(
                    HCAOwnerAndSessionValidator.isValidSignatureWithSender,
                    (INTENT_EXECUTOR, digest, signature)
                )
            );
        assert(!success);
        assert(result.length == 4);
        assert(bytes4(result) == HCAOwnerAndSessionValidator.OwnerUnavailable.selector);
    }

    /// @notice An account without the owner-query interface fails closed.
    function check_unavailableOwnerFailsClosed(bytes32 digest) public {
        bytes memory signature = _sign(OWNER_KEY, digest);
        vm.prank(PAYMENT_TOKEN);
        (bool success, ) =
            address(validator).staticcall(
                abi.encodeCall(
                    HCAOwnerAndSessionValidator.isValidSignatureWithSender,
                    (INTENT_EXECUTOR, digest, signature)
                )
            );
        assert(!success);
    }

    /// @notice Only the validator module type is advertised for arbitrary type identifiers.
    function check_moduleType(uint256 moduleType) public view {
        assert(validator.isModuleType(moduleType) == (moduleType == MODULE_TYPE_VALIDATOR));
    }

    /// @notice Module hooks never install reusable permission state or change initialization status.
    function check_moduleRemainsStateless(
        address queriedAccount,
        bytes32 permissionId,
        bytes32 hookData
    )
        public
    {
        assert(validator.isInitialized(queriedAccount));
        assert(!validator.isPermissionEnabled(queriedAccount, permissionId));
        (bool installed, ) =
            address(validator).call(
                abi.encodeCall(HCAOwnerAndSessionValidator.onInstall, (abi.encode(hookData)))
            );
        assert(installed);
        assert(!validator.isPermissionEnabled(queriedAccount, permissionId));
        (bool uninstalled, ) =
            address(validator).call(
                abi.encodeCall(HCAOwnerAndSessionValidator.onUninstall, (abi.encode(hookData)))
            );
        assert(uninstalled);
        assert(!validator.isPermissionEnabled(queriedAccount, permissionId));
        assert(validator.isInitialized(queriedAccount));
    }

    /// @notice A mismatched UserOperation sender fails even with a canonical owner signature.
    function check_userOpSenderBinding(address sender, bytes32 digest, uint256 nonce) public {
        vm.assume(sender != address(account));
        PackedUserOperation memory operation;
        operation.sender = sender;
        operation.nonce = nonce;
        operation.signature = _sign(OWNER_KEY, digest);
        assert(_userOpResult(operation, digest) == VALIDATION_FAILED);
    }

    /// @notice Owner raw signatures validate matching-account UserOperations.
    function check_userOpRawOwnerSignature(bytes32 digest, uint256 nonce) public {
        PackedUserOperation memory operation = _userOperation(nonce, _sign(OWNER_KEY, digest));
        assert(_userOpResult(operation, digest) == VALIDATION_SUCCESS);
    }

    /// @notice The UserOperation path accepts implicit personal-sign fallback.
    function check_userOpPersonalSignFallback(bytes32 digest) public {
        PackedUserOperation memory operation =
            _userOperation(0, _sign(OWNER_KEY, MessageHashUtils.toEthSignedMessageHash(digest)));
        assert(_userOpResult(operation, digest) == VALIDATION_SUCCESS);
    }

    /// @notice Explicit personal-sign markers validate matching-account UserOperations.
    function check_userOpExplicitPersonalSign(bytes32 digest) public {
        bytes memory signature = _sign(OWNER_KEY, MessageHashUtils.toEthSignedMessageHash(digest));
        signature[signature.length - 1] = bytes1(uint8(signature[signature.length - 1]) + 4);
        assert(_userOpResult(_userOperation(0, signature), digest) == VALIDATION_SUCCESS);
    }

    /// @notice Compact raw recovery identifiers validate matching-account UserOperations.
    function check_userOpCompactRecoveryId(bytes32 digest) public {
        bytes memory signature = _sign(OWNER_KEY, digest);
        signature[signature.length - 1] = bytes1(uint8(signature[signature.length - 1]) - 27);
        assert(_userOpResult(_userOperation(0, signature), digest) == VALIDATION_SUCCESS);
    }

    /// @notice A non-owner key is rejected when its signature explicitly selects personal signing.
    /// @dev Explicit wrapping avoids relying on unconstrained recovery of the same signature at a second digest.
    function check_userOpWrongExplicitSigner(bytes32 digest) public {
        bytes memory signature = _sign(OTHER_KEY, MessageHashUtils.toEthSignedMessageHash(digest));
        signature[signature.length - 1] = bytes1(uint8(signature[signature.length - 1]) + 4);
        assert(_userOpResult(_userOperation(0, signature), digest) == VALIDATION_FAILED);
    }

    /// @notice Every scalar above the canonical half-order threshold fails before either recovery attempt.
    function check_userOpHighSGuard(bytes32 digest, bytes32 r, uint256 highS) public {
        vm.assume(highS > SECP256K1_ORDER / 2);
        bytes memory signature = abi.encodePacked(r, bytes32(highS), uint8(27));
        assert(_userOpResult(_userOperation(0, signature), digest) == VALIDATION_FAILED);
    }

    /// @notice Unsupported recovery identifiers fail before either UserOperation recovery attempt.
    function check_userOpRecoveryIdGuard(bytes32 digest, bytes32 r, bytes32 s, uint8 v) public {
        vm.assume(v != 0 && v != 1 && v != 27 && v != 28 && v != 31 && v != 32);
        assert(
            _userOpResult(_userOperation(0, abi.encodePacked(r, s, v)), digest) == VALIDATION_FAILED
        );
    }

    /// @notice A fixed-width truncated signature returns failure without discarding the proof path.
    function check_userOpTruncatedSignature(bytes32 digest, bytes32 r, bytes32 s) public {
        assert(_userOpResult(_userOperation(0, abi.encodePacked(r, s)), digest) == VALIDATION_FAILED);
    }

    /// @dev Returns a matching-account UserOperation without unrelated dynamic fields.
    function _userOperation(uint256 nonce, bytes memory signature)
        private
        view
        returns (PackedUserOperation memory operation)
    {
        operation.sender = address(account);
        operation.nonce = nonce;
        operation.signature = signature;
    }

    /// @dev Requires successful ABI completion before inspecting the explicit ERC-4337 result.
    function _userOpResult(PackedUserOperation memory operation, bytes32 digest)
        private
        returns (uint256)
    {
        vm.prank(address(account));
        (bool success, bytes memory result) =
            address(validator).staticcall(
                abi.encodeCall(HCAOwnerAndSessionValidator.validateUserOp, (operation, digest))
            );
        assert(success);
        assert(result.length == 32);
        return abi.decode(result, (uint256));
    }
}
