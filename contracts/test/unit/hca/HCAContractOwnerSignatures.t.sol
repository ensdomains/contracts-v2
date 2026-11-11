// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Test} from "forge-std/Test.sol";

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {HCAOwnerAndSessionValidatorTest} from "./HCAOwnerAndSessionValidator.t.sol";
import {HCAFundingSessionValidatorTest} from "./HCAFundingSessionValidator.t.sol";

import {HCAFundingSessionValidator} from "~src/hca/HCAFundingSessionValidator.sol";
import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {HCASmartSessionLib} from "~src/hca/libraries/HCASmartSessionLib.sol";

import {MockStandaloneHCA} from "../../mocks/MockStandaloneHCAStack.sol";

/// @notice Representative ERC-1271 owner with storage-backed one- or two-signature authorization.
/// @dev Exercises ERC-1271 semantics independently of a particular production wallet.
contract MockContractOwner {
    address public first;
    address public second;
    uint256 public threshold;
    bool public enabled;
    error AlreadyInitialized();

    function initialize(address first_, address second_, uint256 threshold_) external {
        if (first != address(0))
            revert AlreadyInitialized();
        first = first_;
        second = second_;
        threshold = threshold_;
        enabled = true;
    }
    function disable() external {
        enabled = false;
    }
    function isValidSignature(bytes32 digest, bytes calldata signatures)
        external
        view
        returns (bytes4)
    {
        if (
            !enabled ||
            signatures.length != threshold * 65 ||
            _recover(digest, signatures[:65]) != first
        )
            return 0xffffffff;
        if (threshold == 2 && _recover(digest, signatures[65:]) != second)
            return 0xffffffff;
        return 0x1626ba7e;
    }
    function _recover(bytes32 digest, bytes calldata sig) private pure returns (address signer) {
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
        return ecrecover(digest, v, r, s);
    }
}


/// @notice Opaque-signature fixture for a 7702 wallet using its own account storage.
/// @dev Models a wallet-defined verifier boundary, not an alternative cryptographic algorithm.
contract Opaque7702Wallet {
    bytes32 private _digest;
    bytes32 private _signatureHash;
    error CallerNotOwner();

    function approve(bytes32 digest, bytes32 signatureHash) external {
        if (msg.sender != address(this))
            revert CallerNotOwner();
        _digest = digest;
        _signatureHash = signatureHash;
    }
    function isValidSignature(bytes32 digest, bytes calldata signature)
        external
        view
        returns (bytes4)
    {
        return
            digest == _digest && keccak256(signature) == _signatureHash
                ? bytes4(0x1626ba7e)
                : bytes4(0xffffffff);
    }
}


/// @notice Rejects proofs after changing a 7702 account's delegated code.
contract Rejecting7702Wallet {
    function isValidSignature(bytes32, bytes calldata) external pure returns (bytes4) {
        return 0xffffffff;
    }
}


/// @notice Storage-slot proxy exercising verification through a wallet proxy.
contract MockOwnerProxy {
    bytes32 private constant SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    constructor(address implementation) {
        bytes32 slot = SLOT;
        assembly { sstore(slot, implementation) }
    }
    fallback() external {
        bytes32 slot = SLOT;
        assembly {
            let implementation := sload(slot)
            calldatacopy(0, 0, calldatasize())
            let success := delegatecall(gas(), implementation, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            if iszero(success) { revert(0, returndatasize()) }
            return(0, returndatasize())
        }
    }
}


/// @dev Helpers for wallet-defined owner signatures and delegated account storage.
abstract contract ContractOwnerTestSupport is Test {
    uint256 internal constant SECOND_KEY = 0xB0B;
    address internal walletImplementation;
    address internal walletAddress;
    uint256 internal walletThreshold;
    function _wallet(address signer, uint256 threshold_, bool proxy)
        internal
        returns (address result)
    {
        walletImplementation = address(new MockContractOwner());
        result = proxy ? address(new MockOwnerProxy(walletImplementation)) : walletImplementation;
        MockContractOwner(result).initialize(signer, vm.addr(SECOND_KEY), threshold_);
        walletAddress = result;
        walletThreshold = threshold_;
    }
    function _delegatedWallet(uint256 rootKey, uint256 threshold_)
        internal
        returns (address result)
    {
        walletImplementation = address(new MockContractOwner());
        result = vm.addr(rootKey);
        vm.signAndAttachDelegation(walletImplementation, rootKey);
        MockContractOwner(result).initialize(result, vm.addr(SECOND_KEY), threshold_);
        assertEq(result.code, abi.encodePacked(hex"ef0100", walletImplementation));
        assertEq(MockContractOwner(result).first(), result);
        walletAddress = result;
        walletThreshold = threshold_;
    }
    function _signature(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        return abi.encodePacked(r, s, v);
    }
    function _replaceProofSignature(
        bytes memory envelope,
        uint256 signatureOffset,
        bytes memory sig,
        bytes1 mode
    )
        internal
        pure
        returns (bytes memory result)
    {
        result = new bytes(envelope.length - 65 + 2 + sig.length);
        for (uint256 i; i < signatureOffset; ++i)
            result[i] = envelope[i];
        result[0] = mode;
        result[signatureOffset] = bytes1(uint8(sig.length >> 8));
        result[signatureOffset + 1] = bytes1(uint8(sig.length));
        for (uint256 i; i < sig.length; ++i)
            result[signatureOffset + 2 + i] = sig[i];
        for (uint256 i = signatureOffset + 65; i < envelope.length; ++i)
            result[i - 65 + 2 + sig.length] = envelope[i];
    }
    function _prefixSig(bytes32 r, bytes32 s, uint8 v, bytes32 digest)
        internal
        view
        returns (bytes memory sig)
    {
        sig = abi.encodePacked(r, s, v);
        if (walletThreshold == 2)
            sig = bytes.concat(sig, _signature(SECOND_KEY, digest));
    }
}


/// @notice Regression coverage for EOA and contract-owner destination authorizations.
contract HCADestinationContractOwnerTest is
    HCAOwnerAndSessionValidatorTest,
    ContractOwnerTestSupport
{
    function _destinationEnvelope(bool sameChain, bool sca)
        internal
        view
        returns (bytes32 digest, bytes memory envelope)
    {
        (SessionEnableProofFixture memory proof, bytes32 permissionId) = _multiChainEnableProof();
        bytes memory operation = _initialCommitOperation(permissionId, proof);
        if (sameChain) {
            HCAOwnerAndSessionValidator.GasRefund memory refund =
                HCAOwnerAndSessionValidator.GasRefund(
                    proof.refundToken,
                    proof.maxRefundExchangeRate,
                    (uint256(proof.maxRefundAmount) << 128) | proof.maxRefundGasOverhead
                );
            digest = validator.singleChainDigestWithRefundHarness(
                address(hca),
                71,
                operation,
                refund
            );
            envelope = _initialRefundEnvelope(permissionId, proof, 71, refund, operation, digest);
        } else {
            bytes memory claim;
            (claim, digest) = _claim(operation, address(hca), block.chainid);
            envelope = _initialEnvelope(permissionId, proof, claim, operation, digest);
        }
        if (sca) {
            bytes32[] memory chainHashes = new bytes32[](proof.hashesAndChainIds.length);
            for (uint256 i; i < chainHashes.length; ++i)
                chainHashes[i] = keccak256(
                    abi.encode(
                        CHAIN_SESSION_TYPEHASH,
                        proof.hashesAndChainIds[i].chainId,
                        proof.hashesAndChainIds[i].sessionDigest
                    )
                );
            bytes32 authDigest = HCASmartSessionLib.multiChainDigest(chainHashes);
            bytes memory sig = _prefixSig(proof.ownerR, proof.ownerS, proof.ownerV, authDigest);
            envelope = _replaceProofSignature(
                envelope,
                33 + 110 + 40 * chainHashes.length,
                sig,
                sameChain ? bytes1(0x08) : bytes1(0x07)
            );
        }
    }
    function _assertDestination(bool sameChain, bool sca) internal {
        (bytes32 digest, bytes memory envelope) = _destinationEnvelope(sameChain, sca);
        assertEq(hca.validate(validator, digest, envelope), bytes4(0x1626ba7e));
    }
    function _sca(uint256 threshold_, bool proxy) internal {
        owner = _wallet(vm.addr(OWNER_KEY), threshold_, proxy);
        hca = new MockStandaloneHCA(owner);
    }
    function test_eoa_destination_cross() public {
        _assertDestination(false, false);
    }
    function test_eoa_destination_same() public {
        _assertDestination(true, false);
    }
    function test_sca_destination_direct1() public {
        _sca(1, false);
        _assertDestination(false, true);
    }
    function test_sca_destination_proxy1() public {
        _sca(1, true);
        _assertDestination(false, true);
    }
    function test_sca_destination_proxy2() public {
        _sca(2, true);
        _assertDestination(false, true);
    }
    function test_sca_destination_same_proxy1() public {
        _sca(1, true);
        _assertDestination(true, true);
    }
    function test_sca_destination_same_proxy2() public {
        _sca(2, true);
        _assertDestination(true, true);
    }
    function test_eoa_owner_intent() public {
        bytes32 digest = keccak256("owner-intent");
        assertEq(hca.validate(validator, digest, _signature(OWNER_KEY, digest)), bytes4(0x1626ba7e));
    }
    function test_sca_owner_intent() public {
        _sca(2, true);
        bytes32 digest = keccak256("owner-intent");
        bytes memory sig =
            abi.encode(
                bytes1(0x06),
                bytes.concat(_signature(OWNER_KEY, digest), _signature(SECOND_KEY, digest))
            );
        assertEq(hca.validate(validator, digest, sig), bytes4(0x1626ba7e));
    }
    function test_sca_rejectsRevokedOwnerAndWrongSignerAndTruncatedProof() public {
        _sca(1, true);
        (bytes32 digest, bytes memory envelope) = _destinationEnvelope(false, true);
        assertEq(hca.validate(validator, digest, envelope), bytes32(bytes4(0x1626ba7e)));
        bytes memory invalid = abi.encode(bytes1(0x06), _signature(SECOND_KEY, digest));
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, invalid);
        MockContractOwner(owner).disable();
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, envelope);
        envelope[223] = 0xff;
        envelope[224] = 0xff;
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSessionData.selector);
        hca.validate(validator, digest, envelope);
    }
    function test_sca_rejectsRevertAndShortMagicReturn() public {
        _sca(1, true);
        bytes32 digest = keccak256("bad-wallet-return");
        bytes memory raw = _signature(OWNER_KEY, digest);
        bytes memory envelope = abi.encode(bytes1(0x06), raw);
        bytes memory callData =
            abi.encodeWithSignature("isValidSignature(bytes32,bytes)", digest, raw);
        vm.mockCall(owner, callData, hex"1626ba7e");
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, envelope);
        vm.clearMockedCalls();
        vm.mockCallRevert(owner, callData, hex"deadbeef");
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, envelope);
    }
    function test_sca_sessionNonceStillRevokesAuthorization() public {
        _sca(1, true);
        (bytes32 digest, bytes memory envelope) = _destinationEnvelope(false, true);
        hca.setSessionNonce(1);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSessionData.selector);
        hca.validate(validator, digest, envelope);
    }
    function test_sca_ownerUserOpRemainsUnsupported() public {
        _sca(1, true);
        bytes32 digest = keccak256("user-operation");
        PackedUserOperation memory op;
        op.sender = address(hca);
        op.signature = abi.encode(bytes1(0x06), _signature(OWNER_KEY, digest));
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(op, digest), 1);
        op.signature = abi.encode(bytes1(0x06), _signature(SECOND_KEY, digest));
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(op, digest), 1);
        op.signature = hex"060000";
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(op, digest), 1);
    }
    function test_7702_destination_cross1() public {
        owner = _delegatedWallet(OWNER_KEY, 1);
        _assertDestination(false, true);
    }
    function test_7702_destination_same1() public {
        owner = _delegatedWallet(OWNER_KEY, 1);
        _assertDestination(true, true);
    }
    function test_7702_destination_cross2() public {
        owner = _delegatedWallet(OWNER_KEY, 2);
        _assertDestination(false, true);
    }
    function test_7702_rootSignaturesAndUserOpsStayValidWithoutWalletReads() public {
        _delegatedWallet(OWNER_KEY, 1);
        bytes32 digest = keccak256("root user operation");
        bytes memory signature = _signature(OWNER_KEY, digest);
        MockContractOwner(owner).disable();
        assertEq(hca.validate(validator, digest, signature), bytes4(0x1626ba7e));
        (digest, signature) = _destinationEnvelope(false, false);
        assertEq(hca.validate(validator, digest, signature), bytes4(0x1626ba7e));
        PackedUserOperation memory op;
        op.sender = address(hca);
        digest = keccak256("root user operation");
        op.signature = _signature(OWNER_KEY, digest);
        vm.record();
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(op, digest), 0);
        (bytes32[] memory reads, bytes32[] memory writes) = vm.accesses(owner);
        assertEq(reads.length, 0);
        assertEq(writes.length, 0);
    }
    function test_7702_sessionProofIsRecheckedAndHcaRevocationStillApplies() public {
        _delegatedWallet(OWNER_KEY, 1);
        (bytes32 digest, bytes memory envelope) = _destinationEnvelope(false, true);
        assertEq(hca.validate(validator, digest, envelope), bytes4(0x1626ba7e));
        assertEq(hca.validate(validator, digest, envelope), bytes4(0x1626ba7e));
        MockContractOwner(owner).disable();
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, envelope);
        hca.setSessionNonce(1);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSessionData.selector);
        hca.validate(validator, digest, envelope);
    }
    function test_7702_ownerAcceptsOpaqueProofInAccountStorage() public {
        address implementation = address(new Opaque7702Wallet());
        bytes32 digest = keccak256("opaque signature authorization");
        bytes memory proof = abi.encode(bytes32("wallet-defined-proof"), new bytes(173));
        vm.signAndAttachDelegation(implementation, OWNER_KEY);
        vm.prank(owner);
        Opaque7702Wallet(owner).approve(digest, keccak256(proof));
        bytes memory envelope = abi.encode(bytes1(0x06), proof);
        assertGt(proof.length, 65);
        assertEq(hca.validate(validator, digest, envelope), bytes4(0x1626ba7e));
        assertEq(
            Opaque7702Wallet(implementation).isValidSignature(digest, proof),
            bytes4(0xffffffff)
        );
        PackedUserOperation memory op;
        op.sender = address(hca);
        op.signature = envelope;
        vm.prank(address(hca));
        assertEq(validator.validateUserOp(op, digest), 1);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, keccak256("wrong digest"), envelope);
    }
    function testFuzz_contractSessionPreservesOpaqueSignatures(uint16 length, bool sameChain)
        public
    {
        length = uint16(bound(length, 0, 512));
        _sca(1, true);
        (bytes32 digest, bytes memory legacy) = _destinationEnvelope(sameChain, false);
        (SessionEnableProofFixture memory proof, ) = _multiChainEnableProof();
        bytes memory opaque = new bytes(length);
        for (uint256 i; i < length; ++i)
            opaque[i] = bytes1(uint8(i));
        bytes32[] memory hashes = new bytes32[](proof.hashesAndChainIds.length);
        for (uint256 i; i < hashes.length; ++i) {
            hashes[i] = HCASmartSessionLib.chainSessionHash(
                proof.hashesAndChainIds[i].chainId,
                proof.hashesAndChainIds[i].sessionDigest
            );
        }
        bytes memory expectedCall =
            abi.encodeWithSignature(
                "isValidSignature(bytes32,bytes)",
                HCASmartSessionLib.multiChainDigest(hashes),
                opaque
            );
        vm.mockCall(owner, expectedCall, abi.encode(bytes4(0x1626ba7e)));
        vm.expectCall(owner, expectedCall);
        bytes memory envelope =
            _replaceProofSignature(
                legacy,
                33 + 110 + 40 * hashes.length,
                opaque,
                sameChain ? bytes1(0x08) : bytes1(0x07)
            );
        assertEq(hca.validate(validator, digest, envelope), bytes4(0x1626ba7e));
    }

    function test_contractOwnerRejectsMalformedAbiEnvelopes() public {
        _sca(1, true);
        bytes32 digest = keccak256("malformed-owner");
        bytes memory valid = abi.encode(bytes1(0x06), _signature(OWNER_KEY, digest));
        bytes memory wrongOffset = bytes.concat(valid);
        wrongOffset[63] = 0x20;
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, wrongOffset);
        bytes memory wrongLength = bytes.concat(valid);
        wrongLength[95] = 0xff;
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, wrongLength);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, bytes.concat(valid, hex"00"));
    }

    function test_7702_changingOrClearingDelegationInvalidatesWalletProof() public {
        _delegatedWallet(OWNER_KEY, 1);
        (bytes32 digest, bytes memory envelope) = _destinationEnvelope(false, true);
        assertEq(hca.validate(validator, digest, envelope), bytes4(0x1626ba7e));
        address rejecting = address(new Rejecting7702Wallet());
        vm.signAndAttachDelegation(rejecting, OWNER_KEY);
        hca.owner();
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, envelope);
        vm.signAndAttachDelegation(address(0), OWNER_KEY);
        hca.owner();
        assertEq(owner.code.length, 0);
        vm.expectRevert(HCAOwnerAndSessionValidator.InvalidSigner.selector);
        hca.validate(validator, digest, envelope);
        digest = keccak256("root after clearing");
        assertEq(hca.validate(validator, digest, _signature(OWNER_KEY, digest)), bytes4(0x1626ba7e));
    }
}


/// @notice Regression coverage for EOA and contract-owner funding authorizations.
contract HCASourceContractOwnerTest is HCAFundingSessionValidatorTest, ContractOwnerTestSupport {
    function _sca(uint256 threshold_, bool proxy) internal {
        owner = _wallet(vm.addr(OWNER_KEY), threshold_, proxy);
        vm.prank(nexus);
        validator.onUninstall("");
        config.owner = owner;
        config.permissionId = _permissionId(config);
        vm.prank(nexus);
        validator.onInstall(abi.encode(config));
    }
    function _sourceEnvelope(bool sca)
        internal
        view
        returns (bytes32 digest, bytes memory envelope)
    {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        bytes memory operation = _fundingOperation(COMMIT_SOURCE_COST, false);
        bytes memory claim;
        (claim, digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 88);
        envelope = _envelope(proof, digest, claim, operation);
        if (sca) {
            bytes32[] memory hashes = new bytes32[](proof.hashesAndChainIds.length);
            for (uint256 i; i < hashes.length; ++i)
                hashes[i] = keccak256(
                    abi.encode(
                        CHAIN_SESSION_TYPEHASH,
                        proof.hashesAndChainIds[i].chainId,
                        proof.hashesAndChainIds[i].sessionDigest
                    )
                );
            bytes32 authDigest = HCASmartSessionLib.multiChainDigest(hashes);
            envelope = _replaceProofSignature(
                envelope,
                33 + 2 + 40 * hashes.length,
                _prefixSig(proof.ownerR, proof.ownerS, proof.ownerV, authDigest),
                0x07
            );
        }
    }
    function _assertSource(bool sca) internal {
        (bytes32 digest, bytes memory envelope) = _sourceEnvelope(sca);
        assertEq(_validate(digest, envelope), bytes4(0x1626ba7e));
    }
    function test_eoa_source() public {
        _assertSource(false);
    }
    function test_sca_source_direct1() public {
        _sca(1, false);
        _assertSource(true);
    }
    function test_sca_source_proxy1() public {
        _sca(1, true);
        _assertSource(true);
    }
    function test_sca_source_proxy2() public {
        _sca(2, true);
        _assertSource(true);
    }
    function test_7702_source1() public {
        _delegatedWallet(OWNER_KEY, 1);
        _assertSource(true);
    }
    function test_7702_source2() public {
        _delegatedWallet(OWNER_KEY, 2);
        _assertSource(true);
    }
    function test_7702_sourceProofIsRechecked() public {
        _delegatedWallet(OWNER_KEY, 1);
        (bytes32 digest, bytes memory envelope) = _sourceEnvelope(true);
        assertEq(_validate(digest, envelope), bytes4(0x1626ba7e));
        MockContractOwner(owner).disable();
        vm.expectRevert(HCAFundingSessionValidator.InvalidSession.selector);
        _validate(digest, envelope);
    }
}
