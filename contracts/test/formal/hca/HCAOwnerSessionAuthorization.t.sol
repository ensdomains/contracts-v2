// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Execution} from "nexus/types/DataTypes.sol";

import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {HCASignatureLib} from "~src/hca/libraries/HCASignatureLib.sol";
import {HCASmartSessionLib} from "~src/hca/libraries/HCASmartSessionLib.sol";
import {HCAOperationHashLib} from "~src/hca/libraries/HCAOperationHashLib.sol";

import {OwnerSessionFixture} from "./owner/OwnerSessionFixture.sol";

/// @title HCA Session Authorization and Binding Proofs
/// @notice Checks complete same-chain session envelopes through the production ERC-1271 entry point.
/// @dev Bounds operations to one commit and authorizations to one chain, except the explicitly named
///      two-chain check. Nonces, deadlines, commitments, and selected limits remain symbolic.
///      Hash collision resistance and signing/recovery are Halmos cryptographic assumptions.
///      Session nonce transitions use the account-interface mock; they do not prove the HCA's nonce writer.
contract HCAOwnerSessionAuthorization is OwnerSessionFixture {
    /// @notice Replays the concrete values reported by the symbolic domain-binding model.
    function test_executorDomainReplay() public {
        check_executorDomainBinding(uint64(block.chainid), address(0));
    }

    /// @notice Replays the concrete values reported by the symbolic chain-array model.
    function test_twoChainReplay() public {
        check_twoChainAuthorization(true, 0, bytes32(0));
    }

    /// @notice A valid reusable proof accepts arbitrary session and intent nonces and commitments.
    function check_validSessionCommit(uint96 sessionNonce, uint256 intentNonce, bytes32 commitment)
        public
    {
        account.setSessionNonce(sessionNonce);
        _accept(_envelope(_proof(), _commit(commitment), intentNonce, _noRefund()));
    }

    /// @notice Validation is reusable and never consumes the session nonce or installs permission state.
    function check_sessionValidationIsStateless(uint96 sessionNonce, bytes32 commitment) public {
        account.setSessionNonce(sessionNonce);
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        Envelope memory envelope = _envelope(proof, _commit(commitment), 0, _noRefund());
        (bytes32 permissionId, ) =
            _packedProof(proof, address(account), uint64(block.chainid), OWNER_KEY);
        _accept(envelope);
        _accept(envelope);
        assert(account.sessionNonce() == sessionNonce);
        assert(account.owner() == owner);
        assert(!validator.isPermissionEnabled(address(account), permissionId));
    }

    /// @notice The exact expiry boundary is accepted and every later timestamp is rejected.
    function check_sessionExpiryBoundary(uint48 now_, uint48 validUntil, bytes32 commitment) public {
        vm.warp(now_);
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.validUntil = validUntil;
        Envelope memory envelope = _envelope(proof, _commit(commitment), 0, _noRefund());
        if (validUntil < now_) {
            _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
        } else {
            _accept(envelope);
        }
    }

    /// @notice Every mismatch between the signed and current account session nonce fails.
    function check_sessionNonceMustMatch(uint96 currentNonce, uint96 signedNonce) public {
        vm.assume(currentNonce != signedNonce);
        account.setSessionNonce(currentNonce);
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.sessionNonce = signedNonce;
        _reject(
            _envelope(proof, _commit(0), 0, _noRefund()),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice A previously accepted proof is rejected after any change in the reported session nonce.
    function check_nonceChangeRevokesExistingProof(uint96 beforeNonce, uint96 afterNonce) public {
        vm.assume(beforeNonce != afterNonce);
        account.setSessionNonce(beforeNonce);
        Envelope memory envelope = _envelope(_proof(), _commit(0), 0, _noRefund());
        _accept(envelope);
        account.setSessionNonce(afterNonce);
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice A zero session key is rejected even when the owner signs that authorization.
    function check_zeroSessionKey() public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.sessionKey = address(0);
        _reject(
            _envelope(proof, _commit(0), 0, _noRefund()),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice Every reusable authorization must name a nonzero funding/refund token.
    function check_zeroAuthorizedRefundToken() public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.refundToken = address(0);
        _reject(
            _envelope(proof, _commit(0), 0, _noRefund()),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice A reusable authorization with no exchange-rate allowance is invalid.
    function check_zeroAuthorizedExchangeRate() public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.maxRefundExchangeRate = 0;
        _reject(
            _envelope(proof, _commit(0), 0, _noRefund()),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice A reusable authorization with no refund amount allowance is invalid.
    function check_zeroAuthorizedRefundAmount() public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.maxRefundAmount = 0;
        _reject(
            _envelope(proof, _commit(0), 0, _noRefund()),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice The single-chain authorization cannot select another entry.
    function check_selectedChainIndex(uint8 selectedIndex) public {
        vm.assume(selectedIndex != 0);
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.sessionToEnableIndex = selectedIndex;
        _reject(
            _envelope(proof, _commit(0), 0, _noRefund()),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice A signed session for another chain cannot authorize the current chain.
    function check_authorizedChainBinding(uint64 authorizedChain) public {
        vm.assume(authorizedChain != block.chainid);
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(proof, address(account), authorizedChain, OWNER_KEY);
        _reject(
            _fromProof(permissionId, packed, 0),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice A signed session for another HCA cannot authorize this account.
    function check_authorizedAccountBinding(address authorizedAccount) public {
        vm.assume(authorizedAccount != address(account));
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), authorizedAccount, uint64(block.chainid), OWNER_KEY);
        _reject(
            _fromProof(permissionId, packed, 0),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice A session authorization signed by another key is rejected before operation execution.
    function check_sessionEnableRequiresOwnerSignature() public {
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OTHER_KEY);
        _reject(
            _fromProof(permissionId, packed, 0),
            HCAOwnerAndSessionValidator.InvalidSigner.selector
        );
    }

    /// @notice A different permission identifier cannot be substituted into an otherwise valid envelope.
    function check_permissionIdBinding(bytes32 differentPermissionId) public {
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OWNER_KEY);
        vm.assume(differentPermissionId != permissionId);
        _reject(
            _fromProof(differentPermissionId, packed, 0),
            HCAOwnerAndSessionValidator.InvalidSessionData.selector
        );
    }

    /// @notice The operation must carry a signature by the enabled session key.
    function check_sessionOperationSigner(bytes32 commitment) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        Envelope memory envelope = _envelope(proof, _commit(commitment), 0, _noRefund());
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(proof, address(account), uint64(block.chainid), OWNER_KEY);
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            0,
            _noRefund(),
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(commitment)),
            envelope.digest,
            OTHER_KEY
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSigner.selector);
    }

    /// @notice A supplied digest must equal the reconstructed same-chain intent digest.
    function check_suppliedDigestBinding(bytes32 commitment, bytes32 suppliedDigest) public {
        Envelope memory envelope = _envelope(_proof(), _commit(commitment), 0, _noRefund());
        vm.assume(suppliedDigest != envelope.digest);
        envelope.digest = suppliedDigest;
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice The signed operation commitment cannot be changed while preserving the signed digest.
    function check_operationCalldataBinding(bytes32 signedCommitment, bytes32 changedCommitment)
        public
    {
        vm.assume(signedCommitment != changedCommitment);
        Envelope memory envelope = _envelope(_proof(), _commit(signedCommitment), 0, _noRefund());
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OWNER_KEY);
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            0,
            _noRefund(),
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(changedCommitment)),
            envelope.digest,
            SESSION_KEY
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice An execution target cannot be changed while preserving the signed intent digest.
    function check_operationTargetBinding(address changedTarget, bytes32 commitment) public {
        vm.assume(changedTarget != address(registrar));
        Execution[] memory executions = _commit(commitment);
        Envelope memory envelope = _envelope(_proof(), executions, 0, _noRefund());
        executions[0].target = changedTarget;
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OWNER_KEY);
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            0,
            _noRefund(),
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, executions),
            envelope.digest,
            SESSION_KEY
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice The intent nonce cannot be changed without changing the signed digest.
    function check_intentNonceBinding(uint256 signedNonce, uint256 changedNonce) public {
        vm.assume(signedNonce != changedNonce);
        Envelope memory envelope = _envelope(_proof(), _commit(0), signedNonce, _noRefund());
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OWNER_KEY);
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            changedNonce,
            _noRefund(),
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(0)),
            envelope.digest,
            SESSION_KEY
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice Only ERC-1271-capable operation modes are valid in a same-chain session envelope.
    function check_operationModeGuard(bytes2 mode) public {
        vm.assume(mode != bytes2(HCAOperationHashLib.ERC7579_ERC1271_MODE));
        vm.assume(mode != bytes2(HCAOperationHashLib.ERC7579_ERC1271_EMISSARY_EXECUTION_MODE));
        Envelope memory envelope = _envelope(_proof(), _commit(0), 0, _noRefund());
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OWNER_KEY);
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            0,
            _noRefund(),
            _encode(bytes32(mode), _commit(0)),
            envelope.digest,
            SESSION_KEY
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector);
    }

    /// @notice The hybrid ERC-1271/emissary operation mode is accepted when included in the signed digest.
    function check_hybridOperationMode(bytes32 commitment, uint256 nonce) public {
        bytes32 mode = HCAOperationHashLib.ERC7579_ERC1271_EMISSARY_EXECUTION_MODE;
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OWNER_KEY);
        Envelope memory envelope;
        envelope.digest = codec.intentDigest(
            address(account),
            nonce,
            _operationHash(mode, _commit(commitment)),
            _noRefund(),
            block.chainid,
            INTENT_EXECUTOR
        );
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            nonce,
            _noRefund(),
            _encode(mode, _commit(commitment)),
            envelope.digest,
            SESSION_KEY
        );
        _accept(envelope);
    }

    /// @notice A fully signed intent for another executor domain is not valid here.
    /// @dev Symbolizing the original chain keeps both domain hashes inside Halmos's collision-resistant hash model.
    function check_executorDomainBinding(uint64 currentChain, address differentExecutor) public {
        vm.chainId(currentChain);
        vm.assume(differentExecutor != INTENT_EXECUTOR);
        Envelope memory envelope = _envelope(_proof(), _commit(0), 0, _noRefund());
        envelope.digest = codec.intentDigest(
            address(account),
            0,
            _operationHash(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(0)),
            _noRefund(),
            block.chainid,
            differentExecutor
        );
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OWNER_KEY);
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            0,
            _noRefund(),
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(0)),
            envelope.digest,
            SESSION_KEY
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice A fully signed intent for another chain domain is rejected despite a current-chain owner proof.
    /// @dev Symbolizing the original chain avoids mixing an untracked concrete hash with a symbolic hash.
    function check_intentChainDomainBinding(uint64 currentChain, uint256 differentChain) public {
        vm.chainId(currentChain);
        vm.assume(differentChain != block.chainid);
        Envelope memory envelope = _envelope(_proof(), _commit(0), 0, _noRefund());
        envelope.digest = codec.intentDigest(
            address(account),
            0,
            _operationHash(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(0)),
            _noRefund(),
            differentChain,
            INTENT_EXECUTOR
        );
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(_proof(), address(account), uint64(block.chainid), OWNER_KEY);
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            0,
            _noRefund(),
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(0)),
            envelope.digest,
            SESSION_KEY
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice Either entry may be selected from a two-chain authorization, including aliased other entries.
    function check_twoChainAuthorization(bool selectedSecond, uint64 otherChain, bytes32 otherDigest)
        public
    {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.sessionToEnableIndex = selectedSecond ? 1 : 0;
        bytes32 salt =
            keccak256(
                abi.encode(
                    proof.sessionNonce,
                    proof.validUntil,
                    proof.resolver,
                    proof.refundToken,
                    proof.maxRefundExchangeRate,
                    proof.maxRefundGasOverhead,
                    proof.maxRefundAmount
                )
            );
        (bytes32 permissionId, bytes32 selectedDigest) =
            HCASmartSessionLib.authorizationHashes(address(account), sessionKey, salt);
        bytes memory selected = abi.encodePacked(uint64(block.chainid), selectedDigest);
        bytes memory other = abi.encodePacked(otherChain, otherDigest);
        bytes32[] memory hashes = new bytes32[](2);
        bytes32 selectedHash =
            HCASmartSessionLib.chainSessionHash(uint64(block.chainid), selectedDigest);
        bytes32 otherHash = HCASmartSessionLib.chainSessionHash(otherChain, otherDigest);
        hashes[0] = selectedSecond ? otherHash : selectedHash;
        hashes[1] = selectedSecond ? selectedHash : otherHash;
        bytes memory packed =
            bytes.concat(
                _packHeader(proof, 2),
                selectedSecond ? bytes.concat(other, selected) : bytes.concat(selected, other),
                _sign(OWNER_KEY, HCASmartSessionLib.multiChainDigest(hashes))
            );
        _accept(_fromProof(permissionId, packed, 0));
    }

    /// @notice An authorization declaring no chain entries is rejected explicitly.
    function check_zeroChainCount() public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        Envelope memory envelope = _envelope(proof, _commit(0), 0, _noRefund());
        uint256 countOffset =
            HCASmartSessionLib.ENABLE_PREFIX_LENGTH + _packHeader(proof, 1).length - 1;
        envelope.data[countOffset] = 0;
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice A session envelope truncated before its operation signature is rejected.
    function check_truncatedEnvelope() public {
        Envelope memory envelope = _envelope(_proof(), _commit(0), 0, _noRefund());
        bytes memory data = envelope.data;
        uint256 truncatedLength =
            data.length -
            HCASignatureLib.SIGNATURE_LENGTH -
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(0)).length;
        assembly ("memory-safe") { mstore(data, truncatedLength) }
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @dev Builds a complete one-commit intent using a separately supplied authorization proof.
    function _fromProof(bytes32 permissionId, bytes memory packed, bytes32 commitment)
        private
        view
        returns (Envelope memory envelope)
    {
        bytes32 mode = HCAOperationHashLib.ERC7579_ERC1271_MODE;
        envelope.digest = codec.intentDigest(
            address(account),
            0,
            _operationHash(mode, _commit(commitment)),
            _noRefund(),
            block.chainid,
            INTENT_EXECUTOR
        );
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            0,
            _noRefund(),
            _encode(mode, _commit(commitment)),
            envelope.digest,
            SESSION_KEY
        );
    }
}
