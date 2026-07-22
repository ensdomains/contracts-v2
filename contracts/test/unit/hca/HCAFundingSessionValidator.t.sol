// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// solhint-disable private-vars-leading-underscore, func-name-mixedcase

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {HCAFundingSessionValidator} from "~src/hca/HCAFundingSessionValidator.sol";

contract HCAFundingSessionValidatorTest is Test {
    struct ClaimFixture {
        uint256 nonce;
        uint256 deadline;
        uint256 sourceAmount;
        uint256 destinationAmount;
        uint256 fillExpiry;
        uint128 minGas;
        bytes32 originOpsHash;
        bytes32 destinationOpsHash;
        bytes32 qualifierHash;
    }

    bytes4 constant ERC1271_MAGICVALUE = 0x1626ba7e;
    bytes4 constant PERMIT_SELECTOR =
        bytes4(keccak256("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));

    bytes32 constant DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");
    bytes32 constant PERMIT2_NAME_HASH = keccak256("Permit2");
    bytes32 constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");
    bytes32 constant TOKEN_TYPEHASH = keccak256("Token(address token,uint256 amount)");
    bytes32 constant OPS_TYPEHASH = keccak256("Ops(address to,uint256 value,bytes data)");
    bytes32 constant OP_TYPEHASH =
        keccak256("Op(bytes32 vt,Ops[] ops)Ops(address to,uint256 value,bytes data)");
    bytes32 constant TARGET_TYPEHASH =
        keccak256(
            "Target(address recipient,Token[] tokenOut,uint256 targetChain,uint256 fillExpiry)Token(address token,uint256 amount)"
        );
    bytes32 constant MANDATE_TYPEHASH =
        keccak256(
            "Mandate(Target target,uint128 minGas,Op originOps,Op destOps,bytes32 q)Op(bytes32 vt,Ops[] ops)Ops(address to,uint256 value,bytes data)Target(address recipient,Token[] tokenOut,uint256 targetChain,uint256 fillExpiry)Token(address token,uint256 amount)"
        );
    bytes32 constant PERMIT_TYPEHASH =
        keccak256(
            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,Mandate mandate)Mandate(Target target,uint128 minGas,Op originOps,Op destOps,bytes32 q)Op(bytes32 vt,Ops[] ops)Ops(address to,uint256 value,bytes data)Target(address recipient,Token[] tokenOut,uint256 targetChain,uint256 fillExpiry)Token(address token,uint256 amount)TokenPermissions(address token,uint256 amount)"
        );

    bytes32 constant SMART_SESSION_DOMAIN_TYPEHASH =
        0xb03948446334eb9b2196d5eb166f69b9d49403eb4a12f36de8d3f9f3cb8e15c3;
    bytes32 constant SMART_SESSION_NAME_HASH =
        0x909aaff4c04d02fd420ef163a6d750c002b0a00dc41a031ba039e3fdb4732133;
    bytes32 constant SMART_SESSION_VERSION_HASH =
        0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;
    bytes32 constant SIGNED_SESSION_TYPEHASH =
        0x984917e689987af96289e12c5f5e934fcdf1df4186108f69ff7e8c3df950ce33;
    bytes32 constant CHAIN_SESSION_TYPEHASH =
        0xabc350ff4773ba356e85e2d2ee58d7d7511767acdb108b59058f5b4a5afc074b;
    bytes32 constant MULTI_CHAIN_SESSION_TYPEHASH =
        0xb4323194e4ca3723804b96dc7a0960bde1afff2b080b8b288fdc264c82e21357;
    bytes32 constant DEFAULT_SIGNED_PERMISSIONS_HASH =
        0x242b79d1322c5e6b12b617584cc2d5766cf18be6feb6acfa469ccf289e11e504;

    address constant SMART_SESSION_EMISSARY = 0xad568B3F825A8d5FFc06DD3253526B64D810Ae89;
    address constant OWNABLE_SESSION_VALIDATOR = 0x000000000013fdB5234E4E3162a810F54d9f7E98;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 constant OWNER_KEY = 0xA11CE;
    uint256 constant SESSION_KEY = 0x5E5510;
    uint96 constant TOTAL_SOURCE_BUDGET = 40_000_000;
    uint96 constant COMMIT_SOURCE_COST = 10_000_000;
    uint96 constant REVEAL_SOURCE_COST = TOTAL_SOURCE_BUDGET - COMMIT_SOURCE_COST;
    uint64 constant BASE_SEPOLIA_CHAIN_ID = 84_532;
    uint64 constant ARBITRUM_SEPOLIA_CHAIN_ID = 421_614;

    address owner = vm.addr(OWNER_KEY);
    address sessionKey = vm.addr(SESSION_KEY);
    address nexus = makeAddr("source-nexus");
    address sourceToken = makeAddr("source-token");
    address arbitrumSourceToken = makeAddr("arbitrum-source-token");
    address destinationHca = makeAddr("destination-hca");
    address destinationToken = makeAddr("destination-token");
    address intentExecutor = makeAddr("intent-executor");
    address arbiter = makeAddr("across-arbiter");

    HCAFundingSessionValidator validator;
    HCAFundingSessionValidator.SessionConfig config;

    function setUp() public {
        vm.chainId(BASE_SEPOLIA_CHAIN_ID);
        validator = new HCAFundingSessionValidator(intentExecutor, PERMIT2);
        config = HCAFundingSessionValidator.SessionConfig({permissionId: bytes32(0), owner: owner, validUntil: uint48(
            block.timestamp + 1 days
        ), sessionKey: sessionKey, sourceToken: sourceToken, destinationRecipient: destinationHca, destinationToken: destinationToken, arbiter: arbiter, destinationChainId: 11_155_111, maxSourceAmount: TOTAL_SOURCE_BUDGET, maxDestinationAmount: 2_000_000});
        config.permissionId = _permissionId(config);
        vm.prank(nexus);
        validator.onInstall(abi.encode(config));
    }

    function test_reusesOneOwnerAuthorizationForCommitAndRevealClaims() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);

        bytes memory commitOperation = _fundingOperation(COMMIT_SOURCE_COST, true);
        (bytes memory commitClaim, bytes32 commitDigest) =
            _claim(commitOperation, COMMIT_SOURCE_COST, 100_000, 1);
        assertEq(
            _validate(commitDigest, _envelope(proof, commitDigest, commitClaim, commitOperation)),
            ERC1271_MAGICVALUE
        );

        bytes memory revealOperation = _fundingOperation(REVEAL_SOURCE_COST, false);
        (bytes memory revealClaim, bytes32 revealDigest) =
            _claim(revealOperation, REVEAL_SOURCE_COST, 1_000_000, 2);
        assertEq(
            _validate(revealDigest, _envelope(proof, revealDigest, revealClaim, revealOperation)),
            ERC1271_MAGICVALUE
        );
    }

    function test_reusesOneOwnerAuthorizationAcrossSourceChains() public {
        HCAFundingSessionValidator.SessionConfig memory arbitrumConfig = config;
        arbitrumConfig.sourceToken = arbitrumSourceToken;
        arbitrumConfig.permissionId = _permissionId(arbitrumConfig);
        assertNotEq(config.permissionId, arbitrumConfig.permissionId);

        HCAFundingSessionValidator.FundingAuthorizationProof memory proof =
            _ownerProof(config, arbitrumConfig);

        bytes memory baseOperation = _fundingOperation(COMMIT_SOURCE_COST, true);
        (bytes memory baseClaim, bytes32 baseDigest) =
            _claim(baseOperation, COMMIT_SOURCE_COST, 100_000, 1);
        assertEq(
            _validate(baseDigest, _envelope(proof, baseDigest, baseClaim, baseOperation)),
            ERC1271_MAGICVALUE
        );

        vm.chainId(ARBITRUM_SEPOLIA_CHAIN_ID);
        vm.prank(nexus);
        validator.onUninstall("");
        vm.prank(nexus);
        validator.onInstall(abi.encode(arbitrumConfig));
        config = arbitrumConfig;
        sourceToken = arbitrumSourceToken;
        proof.sessionToEnableIndex = 2;
        bytes memory arbitrumOperation = _fundingOperation(REVEAL_SOURCE_COST, false);
        (bytes memory arbitrumClaim, bytes32 arbitrumDigest) =
            _claim(arbitrumOperation, REVEAL_SOURCE_COST, 1_000_000, 2);
        assertEq(
            _validate(
                arbitrumDigest,
                _envelope(proof, arbitrumDigest, arbitrumClaim, arbitrumOperation)
            ),
            ERC1271_MAGICVALUE
        );
    }

    function test_rejectsClaimWithoutReusableOwnerAuthorization() public {
        bytes memory operation = _fundingOperation(COMMIT_SOURCE_COST, true);
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);
        bytes memory legacyEnvelope =
            abi.encodePacked(
                bytes1(uint8(0)),
                config.permissionId,
                _sessionSignature(digest),
                claim,
                operation
            );

        vm.expectRevert(HCAFundingSessionValidator.InvalidSession.selector);
        _validate(digest, legacyEnvelope);
    }

    function test_rejectsPullAboveSignedPermit2Claim() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        bytes memory operation = _fundingOperation(COMMIT_SOURCE_COST + 1, true);
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);

        vm.expectRevert(HCAFundingSessionValidator.FundingPolicyFailed.selector);
        _validate(digest, _envelope(proof, digest, claim, operation));
    }

    function test_permissionAlwaysRequiresItsOwnerProof() public view {
        assertFalse(validator.isPermissionEnabled(nexus, config.permissionId));
    }

    function test_acceptsIntentExecutorPrecheck() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        bytes memory operation = _fundingOperation(COMMIT_SOURCE_COST, true);
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);

        vm.prank(nexus);
        assertEq(
            validator.isValidSignatureWithSender(
                intentExecutor,
                digest,
                _envelope(proof, digest, claim, operation)
            ),
            ERC1271_MAGICVALUE
        );
    }

    function test_rejectsUnauthorizedSignatureCaller() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        bytes memory operation = _fundingOperation(COMMIT_SOURCE_COST, true);
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);

        vm.expectRevert(HCAFundingSessionValidator.UnauthorizedCaller.selector);
        vm.prank(nexus);
        validator.isValidSignatureWithSender(
            makeAddr("unauthorized-caller"),
            digest,
            _envelope(proof, digest, claim, operation)
        );
    }

    function test_rejectsExpiredSession() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        vm.warp(config.validUntil + 1);
        bytes memory operation = _fundingOperation(COMMIT_SOURCE_COST, true);
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);

        vm.expectRevert(HCAFundingSessionValidator.SessionExpired.selector);
        _validate(digest, _envelope(proof, digest, claim, operation));
    }

    function test_rejectsInvalidOwnerAuthorization() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        proof.ownerR = bytes32(uint256(proof.ownerR) + 1);
        bytes memory operation = _fundingOperation(COMMIT_SOURCE_COST, true);
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);

        vm.expectRevert(HCAFundingSessionValidator.InvalidSession.selector);
        _validate(digest, _envelope(proof, digest, claim, operation));
    }

    function test_rejectsAuthorizationForAnotherSelectedChain() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        proof.hashesAndChainIds[proof.sessionToEnableIndex].chainId = ARBITRUM_SEPOLIA_CHAIN_ID;
        bytes memory operation = _fundingOperation(COMMIT_SOURCE_COST, true);
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);

        vm.expectRevert(HCAFundingSessionValidator.InvalidSession.selector);
        _validate(digest, _envelope(proof, digest, claim, operation));
    }

    function test_rejectsFundingCallsToAnotherTarget() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        bytes memory operation =
            _fundingOperation(COMMIT_SOURCE_COST, true, makeAddr("arbitrary-target"), PERMIT2);
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);

        vm.expectRevert(HCAFundingSessionValidator.FundingPolicyFailed.selector);
        _validate(digest, _envelope(proof, digest, claim, operation));
    }

    function test_rejectsPermit2ApprovalForAnotherSpender() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        bytes memory operation =
            _fundingOperation(COMMIT_SOURCE_COST, true, sourceToken, makeAddr("spender"));
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);

        vm.expectRevert(HCAFundingSessionValidator.FundingPolicyFailed.selector);
        _validate(digest, _envelope(proof, digest, claim, operation));
    }

    function test_rejectsClaimForAnotherRecipient() public {
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof = _ownerProof(config);
        bytes memory operation = _fundingOperation(COMMIT_SOURCE_COST, true);
        (bytes memory claim, bytes32 digest) = _claim(operation, COMMIT_SOURCE_COST, 100_000, 1);
        claim[149] = bytes1(uint8(claim[149]) ^ 1);

        vm.expectRevert(
            abi.encodeWithSelector(HCAFundingSessionValidator.ClaimFieldMismatch.selector, uint8(5))
        );
        _validate(digest, _envelope(proof, digest, claim, operation));
    }

    function test_rejectsUserOperationsAndDirectExecution() public {
        PackedUserOperation memory userOp;
        assertEq(validator.validateUserOp(userOp, bytes32(0)), 1);

        HCAFundingSessionValidator.Operation memory operation;
        vm.expectRevert(HCAFundingSessionValidator.InvalidSession.selector);
        validator.verifyExecution(nexus, bytes32(0), "", operation);
    }

    function _validate(bytes32 digest, bytes memory envelope) internal returns (bytes4 result) {
        vm.prank(nexus);
        return validator.isValidSignatureWithSender(PERMIT2, digest, envelope);
    }

    function _fundingOperation(uint256 pullAmount, bool includePermit)
        internal
        view
        returns (bytes memory)
    {
        return _fundingOperation(pullAmount, includePermit, sourceToken, PERMIT2);
    }

    function _fundingOperation(
        uint256 pullAmount,
        bool includePermit,
        address target,
        address approvalSpender
    )
        internal
        view
        returns (bytes memory)
    {
        HCAFundingSessionValidator.Execution[] memory executions =
            new HCAFundingSessionValidator.Execution[](includePermit ? 3 : 1);
        uint256 offset;
        if (includePermit) {
            executions[offset++] = HCAFundingSessionValidator.Execution({target: target, value: 0, callData: abi.encodeWithSelector(
                PERMIT_SELECTOR,
                owner,
                nexus,
                TOTAL_SOURCE_BUDGET,
                config.validUntil,
                uint8(27),
                bytes32(uint256(1)),
                bytes32(uint256(2))
            )});
            executions[offset++] = HCAFundingSessionValidator.Execution({target: target, value: 0, callData: abi.encodeCall(
                IERC20.approve,
                (approvalSpender, type(uint256).max)
            )});
        }
        executions[offset++] = HCAFundingSessionValidator.Execution({target: target, value: 0, callData: abi.encodeCall(
            IERC20.transferFrom,
            (owner, nexus, pullAmount)
        )});
        return abi.encodePacked(validator.ERC7579_ERC1271_MODE(), abi.encode(executions));
    }

    function _claim(
        bytes memory operationData,
        uint256 sourceAmount,
        uint256 destinationAmount,
        uint256 nonce
    )
        internal
        view
        returns (bytes memory claimData, bytes32 digest)
    {
        ClaimFixture memory claim =
            ClaimFixture({nonce: nonce, deadline: block.timestamp + 1 hours, sourceAmount: sourceAmount, destinationAmount: destinationAmount, fillExpiry: block.timestamp +
            30 minutes, minGas: 1_000_000, originOpsHash: _operationHash(operationData), destinationOpsHash: keccak256(
                abi.encode("destination", nonce)
            ), qualifierHash: keccak256(abi.encode("qualifier", nonce))});
        claimData = bytes.concat(
            abi.encodePacked(
                arbiter,
                claim.nonce,
                claim.deadline,
                uint8(1),
                bytes32(uint256(uint160(sourceToken))),
                claim.sourceAmount
            ),
            abi.encodePacked(
                destinationHca,
                uint256(config.destinationChainId),
                claim.fillExpiry,
                uint8(1),
                bytes32(uint256(uint160(destinationToken))),
                claim.destinationAmount
            ),
            abi.encodePacked(
                claim.minGas,
                claim.originOpsHash,
                claim.destinationOpsHash,
                claim.qualifierHash
            )
        );
        assertEq(claimData.length, 410);
        digest = _permit2Digest(claim);
    }

    function _permit2Digest(ClaimFixture memory claim) internal view returns (bytes32) {
        bytes32 tokenPermissionsHash =
            keccak256(
                abi.encodePacked(
                    keccak256(
                        abi.encode(TOKEN_PERMISSIONS_TYPEHASH, sourceToken, claim.sourceAmount)
                    )
                )
            );
        bytes32 tokenOutHash =
            keccak256(
                abi.encodePacked(
                    keccak256(abi.encode(TOKEN_TYPEHASH, destinationToken, claim.destinationAmount))
                )
            );
        bytes32 targetHash =
            keccak256(
                abi.encode(
                    TARGET_TYPEHASH,
                    destinationHca,
                    tokenOutHash,
                    uint256(config.destinationChainId),
                    claim.fillExpiry
                )
            );
        bytes32 mandateHash =
            keccak256(
                abi.encode(
                    MANDATE_TYPEHASH,
                    targetHash,
                    claim.minGas,
                    claim.originOpsHash,
                    claim.destinationOpsHash,
                    claim.qualifierHash
                )
            );
        bytes32 permitHash =
            keccak256(
                abi.encode(
                    PERMIT_TYPEHASH,
                    tokenPermissionsHash,
                    arbiter,
                    claim.nonce,
                    claim.deadline,
                    mandateHash
                )
            );
        bytes32 domainSeparator =
            keccak256(abi.encode(DOMAIN_TYPEHASH, PERMIT2_NAME_HASH, block.chainid, PERMIT2));
        return MessageHashUtils.toTypedDataHash(domainSeparator, permitHash);
    }

    function _ownerProof(HCAFundingSessionValidator.SessionConfig memory sessionConfig)
        internal
        view
        returns (HCAFundingSessionValidator.FundingAuthorizationProof memory proof)
    {
        return _ownerProof(sessionConfig, sessionConfig);
    }

    function _ownerProof(
        HCAFundingSessionValidator.SessionConfig memory baseConfig,
        HCAFundingSessionValidator.SessionConfig memory arbitrumConfig
    )
        internal
        view
        returns (HCAFundingSessionValidator.FundingAuthorizationProof memory proof)
    {
        bytes32 baseSessionDigest = _signedSessionHash(baseConfig);
        bytes32 arbitrumSessionDigest = _signedSessionHash(arbitrumConfig);

        proof.sessionToEnableIndex = 1;
        proof.hashesAndChainIds = new HCAFundingSessionValidator.HashAndChainId[](3);
        proof.hashesAndChainIds[0] = HCAFundingSessionValidator.HashAndChainId({chainId: uint64(
            baseConfig.destinationChainId
        ), sessionDigest: keccak256("destination-session")});
        proof.hashesAndChainIds[1] = HCAFundingSessionValidator.HashAndChainId({chainId: BASE_SEPOLIA_CHAIN_ID, sessionDigest: baseSessionDigest});
        proof.hashesAndChainIds[2] = HCAFundingSessionValidator.HashAndChainId({chainId: ARBITRUM_SEPOLIA_CHAIN_ID, sessionDigest: arbitrumSessionDigest});

        bytes32[] memory chainSessionHashes = new bytes32[](proof.hashesAndChainIds.length);
        for (uint256 i; i < proof.hashesAndChainIds.length; ++i) {
            HCAFundingSessionValidator.HashAndChainId memory item = proof.hashesAndChainIds[i];
            chainSessionHashes[i] = keccak256(
                abi.encode(CHAIN_SESSION_TYPEHASH, item.chainId, item.sessionDigest)
            );
        }
        bytes32 structHash =
            keccak256(
                abi.encode(
                    MULTI_CHAIN_SESSION_TYPEHASH,
                    keccak256(abi.encodePacked(chainSessionHashes))
                )
            );
        bytes32 domainSeparator =
            keccak256(
                abi.encode(
                    SMART_SESSION_DOMAIN_TYPEHASH,
                    SMART_SESSION_NAME_HASH,
                    SMART_SESSION_VERSION_HASH
                )
            );
        bytes32 digest = MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
        (proof.ownerV, proof.ownerR, proof.ownerS) = vm.sign(OWNER_KEY, digest);
    }

    function _signedSessionHash(HCAFundingSessionValidator.SessionConfig memory sessionConfig)
        internal
        view
        returns (bytes32)
    {
        bytes memory validatorInitData = _sessionValidatorInitData(sessionConfig.sessionKey);
        return
            keccak256(
                abi.encode(
                    SIGNED_SESSION_TYPEHASH,
                    nexus,
                    type(uint256).max,
                    uint256(0),
                    DEFAULT_SIGNED_PERMISSIONS_HASH,
                    _authorizationSalt(sessionConfig),
                    OWNABLE_SESSION_VALIDATOR,
                    keccak256(validatorInitData),
                    SMART_SESSION_EMISSARY
                )
            );
    }

    function _envelope(
        HCAFundingSessionValidator.FundingAuthorizationProof memory proof,
        bytes32 permit2Digest,
        bytes memory claimData,
        bytes memory operationData
    )
        internal
        view
        returns (bytes memory)
    {
        bytes memory proofData = abi.encode(proof);
        return
            abi.encodePacked(
                bytes1(uint8(4)),
                config.permissionId,
                bytes4(uint32(proofData.length)),
                proofData,
                _sessionSignature(permit2Digest),
                claimData,
                operationData
            );
    }

    function _sessionSignature(bytes32 permit2Digest) internal view returns (bytes memory) {
        bytes32 accountBoundHash =
            MessageHashUtils.toEthSignedMessageHash(
                abi.encodePacked(bytes32(uint256(uint160(nexus))), permit2Digest)
            );
        bytes32 personalDigest = MessageHashUtils.toEthSignedMessageHash(accountBoundHash);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(SESSION_KEY, personalDigest);
        return abi.encodePacked(r, s, v + 4);
    }

    function _permissionId(HCAFundingSessionValidator.SessionConfig memory sessionConfig)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    OWNABLE_SESSION_VALIDATOR,
                    _sessionValidatorInitData(sessionConfig.sessionKey),
                    _authorizationSalt(sessionConfig)
                )
            );
    }

    function _authorizationSalt(HCAFundingSessionValidator.SessionConfig memory sessionConfig)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    sessionConfig.owner,
                    sessionConfig.validUntil,
                    sessionConfig.sourceToken,
                    sessionConfig.destinationRecipient,
                    sessionConfig.destinationToken,
                    sessionConfig.arbiter,
                    sessionConfig.destinationChainId,
                    sessionConfig.maxSourceAmount,
                    sessionConfig.maxDestinationAmount
                )
            );
    }

    function _sessionValidatorInitData(address signer) internal pure returns (bytes memory) {
        address[] memory owners = new address[](1);
        owners[0] = signer;
        return abi.encode(uint256(1), owners);
    }

    function _operationHash(bytes memory operationData) internal pure returns (bytes32) {
        bytes32 mode;
        assembly ("memory-safe") {
            mode := mload(add(operationData, 0x20))
        }
        HCAFundingSessionValidator.Execution[] memory executions =
            abi.decode(_slice(operationData, 32), (HCAFundingSessionValidator.Execution[]));
        bytes32[] memory executionHashes = new bytes32[](executions.length);
        for (uint256 i; i < executions.length; ++i) {
            executionHashes[i] = keccak256(
                abi.encode(
                    OPS_TYPEHASH,
                    executions[i].target,
                    executions[i].value,
                    keccak256(executions[i].callData)
                )
            );
        }
        return
            keccak256(abi.encode(OP_TYPEHASH, mode, keccak256(abi.encodePacked(executionHashes))));
    }

    function _slice(bytes memory data, uint256 start) internal pure returns (bytes memory result) {
        result = new bytes(data.length - start);
        for (uint256 i; i < result.length; ++i) {
            result[i] = data[start + i];
        }
    }
}
