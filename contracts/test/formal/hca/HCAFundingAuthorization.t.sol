// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// solhint-disable func-name-mixedcase

import {HCAFundingFixture} from "./funding/HCAFundingFixture.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

import {HCAFundingSessionValidator} from "~src/hca/HCAFundingSessionValidator.sol";
import {HCASignatureLib} from "~src/hca/libraries/HCASignatureLib.sol";
import {HCASmartSessionLib} from "~src/hca/libraries/HCASmartSessionLib.sol";

/// @notice Checks reusable funding authorization binding and canonical signature/envelope guards.
/// @dev Most proofs use one chain entry and one source transfer; the multi-chain check uses exactly
///      two entries. Wrong-key checks assume a distinct signer address and use signatures for the
///      actual digest, avoiding unmodeled claims of ECDSA non-forgeability for a changed digest.
///      Malformed recovery identifiers and high-s checks bypass the valid-signature helper only
///      after constructing an otherwise valid envelope, so its crypto assumptions do not hide them.
/// @custom:halmos --loop 4
contract HCAFundingAuthorization is HCAFundingFixture {
    /// @notice Changing any destination field invalidates the previously signed capability.
    function check_CapabilityBindsDestination(address recipient, address token, uint64 chainId)
        public
    {
        vm.assume(recipient != address(0));
        vm.assume(token != address(0));
        vm.assume(chainId != 0);
        vm.assume(
            recipient != RECIPIENT || token != DESTINATION_TOKEN || chainId != DESTINATION_CHAIN
        );
        HCAFundingSessionValidator.SessionConfig memory replacement = config;
        replacement.destinationRecipient = recipient;
        replacement.destinationToken = token;
        replacement.destinationChainId = chainId;
        _assertOldCapabilityRejected(replacement);
    }

    /// @notice Changing either amount cap invalidates the previously signed capability.
    function check_CapabilityBindsAmountCaps(uint96 sourceCap, uint96 destinationCap) public {
        vm.assume(sourceCap != 0 && destinationCap != 0);
        vm.assume(sourceCap != SOURCE_CAP || destinationCap != DESTINATION_CAP);
        HCAFundingSessionValidator.SessionConfig memory replacement = config;
        replacement.maxSourceAmount = sourceCap;
        replacement.maxDestinationAmount = destinationCap;
        _assertOldCapabilityRejected(replacement);
    }

    /// @notice Changing the source token invalidates the previously signed capability.
    function check_CapabilityBindsSourceToken(address token) public {
        vm.assume(token != address(0) && token != SOURCE_TOKEN);
        HCAFundingSessionValidator.SessionConfig memory replacement = config;
        replacement.sourceToken = token;
        _assertOldCapabilityRejected(replacement);
    }

    /// @notice Changing the owner invalidates the previously signed capability.
    function check_CapabilityBindsOwner(address replacementOwner) public {
        vm.assume(replacementOwner != address(0) && replacementOwner != owner);
        HCAFundingSessionValidator.SessionConfig memory replacement = config;
        replacement.owner = replacementOwner;
        _assertOldCapabilityRejected(replacement);
    }

    /// @notice Changing the session key invalidates the previously signed capability.
    function check_CapabilityBindsSessionKey(address replacementKey) public {
        vm.assume(replacementKey != address(0) && replacementKey != sessionKey);
        HCAFundingSessionValidator.SessionConfig memory replacement = config;
        replacement.sessionKey = replacementKey;
        _assertOldCapabilityRejected(replacement);
    }

    /// @notice Any different live expiry requires fresh owner authorization.
    function check_CapabilityBindsExpiry(uint48 expiry) public {
        vm.assume(expiry > START_TIME && expiry != SESSION_EXPIRY);
        HCAFundingSessionValidator.SessionConfig memory replacement = config;
        replacement.validUntil = expiry;
        _assertOldCapabilityRejected(replacement);
    }

    /// @notice Installation of an arbitrary nonzero permission identifier does not make it usable.
    function check_PermissionMustBeDerivedFromPolicy(bytes32 replacementPermission) public {
        vm.assume(replacementPermission != bytes32(0));
        vm.assume(replacementPermission != config.permissionId);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        HCAFundingSessionValidator.SessionConfig memory replacement = config;
        replacement.permissionId = replacementPermission;
        _replaceConfig(replacement);
        _writeWord(envelope.data, 1, replacementPermission);
        _assertInvalidSession(envelope);
    }

    /// @notice The envelope's permission identifier must match the installed configuration.
    function check_EnvelopePermissionMatchesInstallation(bytes32 permissionId) public {
        vm.assume(permissionId != config.permissionId);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _writeWord(envelope.data, 1, permissionId);
        _assertInvalidSession(envelope);
    }

    /// @notice An identical configuration on another account cannot reuse this account's owner proof.
    function check_OwnerAuthorizationBindsSourceAccount() public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _assertValid(envelope);
        (bool installed, ) = _install(OTHER_ACCOUNT, config);
        assert(installed);
        (bool success, bytes memory result) =
            _validate(OTHER_ACCOUNT, PERMIT2, envelope.digest, envelope.data);
        _assertFailure(
            success,
            result,
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidSession.selector)
        );
    }

    /// @notice A canonical signature from any distinct signer cannot act as the installed owner.
    function check_DifferentOwnerSignerRejected(uint256 privateKey) public {
        _assumeDifferentKey(privateKey, owner);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.data = _joinEnvelope(
            config.permissionId,
            _ownerProofWithKey(ACCOUNT, config, privateKey),
            _sessionSignature(ACCOUNT, envelope.digest),
            envelope.claim,
            envelope.operation
        );
        _assertInvalidSession(envelope);
    }

    /// @notice A canonical signature from any distinct signer cannot act as the installed session key.
    function check_DifferentSessionSignerRejected(uint256 privateKey) public {
        _assumeDifferentKey(privateKey, sessionKey);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        bytes32 accountDigest =
            MessageHashUtils.toEthSignedMessageHash(
                abi.encodePacked(bytes32(uint256(uint160(ACCOUNT))), envelope.digest)
            );
        envelope.data = _joinEnvelope(
            config.permissionId,
            _ownerProof(ACCOUNT, config),
            _sign(privateKey, accountDigest),
            envelope.claim,
            envelope.operation
        );
        _assertInvalidSession(envelope);
    }

    /// @notice The selected chain entry must identify the current source chain.
    function check_SelectedChainBound(uint64 chainId) public {
        vm.assume(chainId != SOURCE_CHAIN);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        uint256 chainOffset = HCASmartSessionLib.ENABLE_PREFIX_LENGTH + 2;
        bytes memory data = envelope.data;
        assembly ("memory-safe") {
            let cursor := add(add(data, 0x20), chainOffset)
            mstore(cursor, or(shl(192, chainId), and(mload(cursor), sub(shl(192, 1), 1))))
        }
        _assertInvalidSession(envelope);
    }

    /// @notice The reusable capability is portable between equivalent funding-validator deployments.
    /// @dev Account, key, policy, chain, and Permit2 domain are bound; this validator's address is not.
    function check_EquivalentValidatorDeploymentAcceptsCapability(uint256 nonce) public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, nonce));
        _assertValid(envelope);
        HCAFundingSessionValidator equivalent = _deployEquivalent(PERMIT2);
        vm.prank(ACCOUNT);
        (bool success, bytes memory result) =
            address(equivalent).staticcall(
                abi.encodeCall(
                    equivalent.isValidSignatureWithSender,
                    (PERMIT2, envelope.digest, envelope.data)
                )
            );
        assert(success);
        assert(result.length == 32);
        // Compare to the production validator's successful public return value.
        (bool originalSuccess, bytes memory originalResult) =
            _validate(ACCOUNT, PERMIT2, envelope.digest, envelope.data);
        assert(originalSuccess);
        assert(keccak256(result) == keccak256(originalResult));
    }

    /// @notice A validator configured with another Permit2 cannot reuse the original claim digest.
    function check_DifferentValidatorPermit2DomainRejectsClaim(address differentPermit2) public {
        vm.assume(differentPermit2 != address(0) && differentPermit2 != PERMIT2);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        HCAFundingSessionValidator different = _deployEquivalent(differentPermit2);
        vm.prank(ACCOUNT);
        (bool success, bytes memory result) =
            address(different).staticcall(
                abi.encodeCall(
                    different.isValidSignatureWithSender,
                    (differentPermit2, envelope.digest, envelope.data)
                )
            );
        _assertFailure(success, result, _fieldError(9));
    }

    /// @notice The selected index must exist in the one-entry owner proof.
    function check_SelectedIndexBound(uint8 selectedIndex) public {
        vm.assume(selectedIndex >= 1);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.data[HCASmartSessionLib.ENABLE_PREFIX_LENGTH] = bytes1(selectedIndex);
        _assertInvalidSession(envelope);
    }

    /// @notice A selected session digest must match the account, session key, and installed policy.
    function check_SelectedSessionDigestBound(bytes32 sessionDigest) public {
        (, bytes32 expected) =
            HCASmartSessionLib.authorizationHashes(ACCOUNT, sessionKey, _authorizationSalt(config));
        vm.assume(sessionDigest != expected);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _writeWord(envelope.data, HCASmartSessionLib.ENABLE_PREFIX_LENGTH + 2 + 8, sessionDigest);
        _assertInvalidSession(envelope);
    }

    /// @notice Either index of a two-chain authorization can select the correctly bound source session.
    function check_TwoChainProofSupportsEitherIndex(
        uint8 selectedIndex,
        uint64 remoteChain,
        bytes32 remoteDigest
    )
        public
    {
        vm.assume(selectedIndex < 2);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.data = _joinEnvelope(
            config.permissionId,
            _twoChainProof(selectedIndex, remoteChain, remoteDigest),
            _sessionSignature(ACCOUNT, envelope.digest),
            envelope.claim,
            envelope.operation
        );
        _assertValid(envelope);
    }

    /// @notice The funding envelope rejects every mode other than its fixed source mode.
    function check_FundingEnvelopeModeIsFixed(bytes1 mode) public {
        vm.assume(mode != FUNDING_MODE);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.data[0] = mode;
        _assertInvalidSession(envelope);
    }

    /// @notice A zero-entry authorization is rejected before reading any owner signature.
    function check_ZeroChainCountRejected() public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.data[HCASmartSessionLib.ENABLE_PREFIX_LENGTH + 1] = bytes1(0);
        _assertInvalidSession(envelope);
    }

    /// @notice A prefix without the required proof, signature, and claim tail is rejected.
    function check_TruncatedEnvelopeRejected(bytes32 permissionId, bytes32 digest) public {
        (bool success, bytes memory result) =
            _validate(ACCOUNT, PERMIT2, digest, abi.encodePacked(FUNDING_MODE, permissionId));
        _assertFailure(
            success,
            result,
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidSession.selector)
        );
    }

    /// @notice A valid claim followed by an operation shorter than its header is rejected.
    function check_TruncatedOperationHeaderRejected(bytes2 operation) public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _assertError(
            _seal(envelope.claim, abi.encodePacked(operation)),
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidOperation.selector)
        );
    }

    /// @notice Every noncanonical owner recovery identifier is rejected before raw recovery.
    function check_InvalidOwnerRecoveryIdentifier(uint8 v) public {
        _assumeInvalidRecoveryIdentifier(v);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.data[OWNER_SIGNATURE_OFFSET + HCASignatureLib.SIGNATURE_LENGTH - 1] = bytes1(v);
        _assertInvalidSession(envelope);
    }

    /// @notice Every noncanonical session recovery identifier is rejected before raw recovery.
    function check_InvalidSessionRecoveryIdentifier(uint8 v) public {
        _assumeInvalidRecoveryIdentifier(v);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.data[SESSION_SIGNATURE_OFFSET + HCASignatureLib.SIGNATURE_LENGTH - 1] = bytes1(v);
        _assertInvalidSession(envelope);
    }

    /// @notice Every high-s owner signature is rejected by the production canonicality guard.
    function check_HighOwnerSignatureRejected(uint256 s) public {
        vm.assume(s > SECP256K1_ORDER / 2);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _writeWord(envelope.data, OWNER_SIGNATURE_OFFSET + 32, bytes32(s));
        _assertInvalidSession(envelope);
    }

    /// @notice Every high-s session signature is rejected by the production canonicality guard.
    function check_HighSessionSignatureRejected(uint256 s) public {
        vm.assume(s > SECP256K1_ORDER / 2);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _writeWord(envelope.data, SESSION_SIGNATURE_OFFSET + 32, bytes32(s));
        _assertInvalidSession(envelope);
    }

    /// @notice Both canonical and compact owner recovery identifiers validate the same signed proof.
    function check_CompactOwnerRecovery(bool compact) public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        if (compact) {
            uint256 offset = OWNER_SIGNATURE_OFFSET + HCASignatureLib.SIGNATURE_LENGTH - 1;
            envelope.data[offset] = bytes1(uint8(envelope.data[offset]) - 27);
        }
        _assertValid(envelope);
    }

    /// @notice Both canonical and compact session recovery identifiers validate the same signed claim.
    function check_CompactSessionRecovery(bool compact) public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        if (compact) {
            uint256 offset = SESSION_SIGNATURE_OFFSET + HCASignatureLib.SIGNATURE_LENGTH - 1;
            envelope.data[offset] = bytes1(uint8(envelope.data[offset]) - 27);
        }
        _assertValid(envelope);
    }

    /// @notice Explicit EIP-191 session recovery validates the additional personal-sign digest layer.
    function check_ExplicitEip191SessionRecovery(uint256 nonce) public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, nonce));
        bytes32 accountDigest =
            MessageHashUtils.toEthSignedMessageHash(
                abi.encodePacked(bytes32(uint256(uint160(ACCOUNT))), envelope.digest)
            );
        bytes memory signature =
            _sign(SESSION_PRIVATE_KEY, MessageHashUtils.toEthSignedMessageHash(accountDigest));
        signature[HCASignatureLib.SIGNATURE_LENGTH - 1] = bytes1(
            uint8(signature[HCASignatureLib.SIGNATURE_LENGTH - 1]) + 4
        );
        envelope.data = _joinEnvelope(
            config.permissionId,
            _ownerProof(ACCOUNT, config),
            signature,
            envelope.claim,
            envelope.operation
        );
        _assertValid(envelope);
    }

    /// @notice Requires the old signed session to fail after a different complete configuration is installed.
    function _assertOldCapabilityRejected(
        HCAFundingSessionValidator.SessionConfig memory replacement
    )
        internal
    {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _assertValid(envelope);
        (replacement.permissionId, ) = HCASmartSessionLib.authorizationHashes(
            ACCOUNT,
            replacement.sessionKey,
            _authorizationSalt(replacement)
        );
        _replaceConfig(replacement);
        _writeWord(envelope.data, 1, replacement.permissionId);
        _assertInvalidSession(envelope);
    }

    /// @notice Creates two ordered chain entries and a matching canonical owner signature.
    function _twoChainProof(uint8 selectedIndex, uint64 remoteChain, bytes32 remoteDigest)
        internal
        view
        returns (bytes memory)
    {
        (, bytes32 currentDigest) =
            HCASmartSessionLib.authorizationHashes(ACCOUNT, sessionKey, _authorizationSalt(config));
        bytes memory entries;
        bytes32[] memory hashes = new bytes32[](2);
        if (selectedIndex == 0) {
            entries = abi.encodePacked(SOURCE_CHAIN, currentDigest, remoteChain, remoteDigest);
            hashes[0] = HCASmartSessionLib.chainSessionHash(SOURCE_CHAIN, currentDigest);
            hashes[1] = HCASmartSessionLib.chainSessionHash(remoteChain, remoteDigest);
        } else {
            entries = abi.encodePacked(remoteChain, remoteDigest, SOURCE_CHAIN, currentDigest);
            hashes[0] = HCASmartSessionLib.chainSessionHash(remoteChain, remoteDigest);
            hashes[1] = HCASmartSessionLib.chainSessionHash(SOURCE_CHAIN, currentDigest);
        }
        uint8 encodedIndex = selectedIndex == 0 ? uint8(0) : uint8(1);
        return
            abi.encodePacked(
                encodedIndex,
                uint8(2),
                entries,
                _sign(OWNER_PRIVATE_KEY, HCASmartSessionLib.multiChainDigest(hashes))
            );
    }

    /// @notice Restricts a generated key to the curve domain and an address distinct from the required signer.
    function _assumeDifferentKey(uint256 privateKey, address requiredSigner) internal pure {
        vm.assume(privateKey > 0);
        vm.assume(privateKey < SECP256K1_ORDER);
        address signer = vm.addr(privateKey);
        vm.assume(signer != address(0));
        vm.assume(signer != requiredSigner);
    }

    /// @notice Deploys an unchanged validator with the same account configuration and selected Permit2 domain.
    function _deployEquivalent(address permit2)
        internal
        returns (HCAFundingSessionValidator equivalent)
    {
        equivalent = new HCAFundingSessionValidator(EXECUTOR, permit2, address(router));
        vm.prank(ACCOUNT);
        (bool success, ) =
            address(equivalent).call(abi.encodeCall(equivalent.onInstall, (abi.encode(config))));
        assert(success);
    }

    /// @notice Excludes exactly the recovery identifiers accepted by the production signature library.
    function _assumeInvalidRecoveryIdentifier(uint8 v) internal pure {
        uint256 accepted =
            (uint256(1) << 0) |
            (uint256(1) << 1) |
            (uint256(1) << 27) |
            (uint256(1) << 28) |
            (uint256(1) << 31) |
            (uint256(1) << 32);
        vm.assume((accepted & (uint256(1) << v)) == 0);
    }

    /// @notice Asserts the production invalid-session failure for a complete or deliberately malformed proof.
    function _assertInvalidSession(FundingEnvelope memory envelope) internal {
        _assertError(
            envelope,
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidSession.selector)
        );
    }
}
