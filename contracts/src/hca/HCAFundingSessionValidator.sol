// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IValidator} from "nexus/interfaces/modules/IValidator.sol";

/// @title HCA Funding Session Validator
/// @notice Fixed validator for a Nexus that funds an HCA registration from another chain.
/// @dev The Nexus installs one session during account creation. The session can pull the
///      owner's permitted token into the Nexus and sign a Permit2 claim that delivers the
///      configured token to the configured HCA.
contract HCAFundingSessionValidator is IValidator {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice Configuration for one Nexus funding session.
    struct SessionConfig {
        bytes32 permissionId;
        address owner;
        uint48 validUntil;
        address sessionKey;
        address sourceToken;
        address destinationRecipient;
        address destinationToken;
        address arbiter;
        uint64 destinationChainId;
        uint96 maxSourceAmount;
        uint96 maxDestinationAmount;
    }

    /// @notice One ERC-7579 execution.
    struct Execution {
        address target;
        uint256 value;
        bytes callData;
    }

    /// @notice Operation supplied by the IntentExecutor.
    struct Operation {
        bytes data;
    }

    /// @dev Permit2 fields exposed by the fixed claim-policy encoding.
    struct ClaimFields {
        address spender;
        uint256 nonce;
        uint256 deadline;
        address sourceToken;
        uint256 sourceAmount;
        address recipient;
        uint256 destinationChainId;
        uint256 fillExpiry;
        address destinationToken;
        uint256 destinationAmount;
    }

    /// @dev One chain and session digest from a standard Rhinestone multi-chain session authorization.
    struct HashAndChainId {
        uint64 chainId;
        bytes32 sessionDigest;
    }

    /// @dev The reusable owner authorization supplied with each source claim.
    struct FundingAuthorizationProof {
        uint8 sessionToEnableIndex;
        HashAndChainId[] hashesAndChainIds;
        bytes32 ownerR;
        bytes32 ownerS;
        uint8 ownerV;
    }

    ////////////////////////////////////////////////////////////////////////
    // Constants & Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @dev ERC-1271 success value.
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;

    /// @dev ERC-4337 validation failure value.
    uint256 internal constant VALIDATION_FAILED = 1;

    /// @dev ERC-7579 validator module type.
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;

    /// @dev Fixed source-session mode carrying the reusable multi-chain owner authorization.
    bytes1 internal constant FUNDING_SESSION_MODE = 0x04;

    /// @dev Size of the mode, permission ID, and four-byte authorization-proof length.
    uint256 internal constant FUNDING_SESSION_PREFIX_LENGTH = 37;

    /// @dev Size of one ECDSA signature.
    uint256 internal constant ECDSA_SIGNATURE_LENGTH = 65;

    /// @dev Size of the Permit2 policy data used by this validator.
    uint256 internal constant CLAIM_POLICY_DATA_LENGTH = 410;

    /// @notice Rhinestone operation mode for ERC-1271 ERC-7579 execution.
    bytes32 public constant ERC7579_ERC1271_MODE = bytes32(uint256(0x0201) << 240);

    /// @notice Rhinestone operation mode for emissary ERC-7579 execution.
    bytes32 public constant ERC7579_EMISSARY_EXECUTION_MODE = bytes32(uint256(0x0204) << 240);

    /// @notice Rhinestone operation mode for ERC-1271 with emissary-execution fallback.
    bytes32 public constant ERC7579_ERC1271_EMISSARY_EXECUTION_MODE =
        bytes32(uint256(0x0206) << 240);

    /// @dev Permit2 EIP-712 domain type hash.
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @dev Permit2 EIP-712 name hash.
    bytes32 internal constant PERMIT2_NAME_HASH = keccak256("Permit2");

    /// @dev Permit2 token-permissions type hash.
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");

    /// @dev Permit2 destination-token type hash.
    bytes32 internal constant TOKEN_TYPEHASH = keccak256("Token(address token,uint256 amount)");

    /// @dev Intent operation-call type hash.
    bytes32 internal constant OPS_TYPEHASH = keccak256("Ops(address to,uint256 value,bytes data)");

    /// @dev Intent operation type hash.
    bytes32 internal constant OP_TYPEHASH =
        keccak256("Op(bytes32 vt,Ops[] ops)Ops(address to,uint256 value,bytes data)");

    /// @dev Permit2 destination target type hash.
    bytes32 internal constant TARGET_TYPEHASH =
        keccak256(
            "Target(address recipient,Token[] tokenOut,uint256 targetChain,uint256 fillExpiry)Token(address token,uint256 amount)"
        );

    /// @dev Permit2 route mandate type hash.
    bytes32 internal constant MANDATE_TYPEHASH =
        keccak256(
            "Mandate(Target target,uint128 minGas,Op originOps,Op destOps,bytes32 q)Op(bytes32 vt,Ops[] ops)Ops(address to,uint256 value,bytes data)Target(address recipient,Token[] tokenOut,uint256 targetChain,uint256 fillExpiry)Token(address token,uint256 amount)"
        );

    /// @dev Permit2 batch witness type hash.
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256(
            "PermitBatchWitnessTransferFrom(TokenPermissions[] permitted,address spender,uint256 nonce,uint256 deadline,Mandate mandate)Mandate(Target target,uint128 minGas,Op originOps,Op destOps,bytes32 q)Op(bytes32 vt,Ops[] ops)Ops(address to,uint256 value,bytes data)Target(address recipient,Token[] tokenOut,uint256 targetChain,uint256 fillExpiry)Token(address token,uint256 amount)TokenPermissions(address token,uint256 amount)"
        );

    /// @dev Canonical Smart Session emissary.
    address internal constant SMART_SESSION_EMISSARY = 0xad568B3F825A8d5FFc06DD3253526B64D810Ae89;

    /// @dev Canonical one-of-one session validator.
    address internal constant OWNABLE_SESSION_VALIDATOR = 0x000000000013fdB5234E4E3162a810F54d9f7E98;

    /// @dev Smart Session EIP-712 domain type hash.
    bytes32 internal constant SMART_SESSION_DOMAIN_TYPEHASH =
        0xb03948446334eb9b2196d5eb166f69b9d49403eb4a12f36de8d3f9f3cb8e15c3;

    /// @dev Smart Session EIP-712 name hash.
    bytes32 internal constant SMART_SESSION_NAME_HASH =
        0x909aaff4c04d02fd420ef163a6d750c002b0a00dc41a031ba039e3fdb4732133;

    /// @dev Smart Session EIP-712 version hash.
    bytes32 internal constant SMART_SESSION_VERSION_HASH =
        0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    /// @dev Signed-session type hash.
    bytes32 internal constant SIGNED_SESSION_TYPEHASH =
        0x984917e689987af96289e12c5f5e934fcdf1df4186108f69ff7e8c3df950ce33;

    /// @dev Chain-session type hash.
    bytes32 internal constant CHAIN_SESSION_TYPEHASH =
        0xabc350ff4773ba356e85e2d2ee58d7d7511767acdb108b59058f5b4a5afc074b;

    /// @dev Multi-chain session type hash.
    bytes32 internal constant MULTI_CHAIN_SESSION_TYPEHASH =
        0xb4323194e4ca3723804b96dc7a0960bde1afff2b080b8b288fdc264c82e21357;

    /// @dev Hash of the default empty Smart Session permissions.
    bytes32 internal constant DEFAULT_SIGNED_PERMISSIONS_HASH =
        0x242b79d1322c5e6b12b617584cc2d5766cf18be6feb6acfa469ccf289e11e504;

    /// @dev Selector for an EIP-2612 permit.
    bytes4 internal constant PERMIT_SELECTOR =
        bytes4(keccak256("permit(address,address,uint256,uint256,uint8,bytes32,bytes32)"));

    /// @notice The only executor allowed to present session operations.
    address public immutable INTENT_EXECUTOR;

    /// @notice The Permit2 contract that requests ERC-1271 claim validation.
    address public immutable PERMIT2;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Installed funding session for each source Nexus.
    mapping(address account => SessionConfig config) internal _sessions;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a Nexus installs a funding session.
    /// @param account The Nexus that installed the session.
    /// @param permissionId The permission used by the Rhinestone SDK.
    /// @param sessionKey The authorized session signer.
    /// @param destinationRecipient The HCA that receives bridged funds.
    event SessionInstalled(
        address indexed account,
        bytes32 indexed permissionId,
        address indexed sessionKey,
        address destinationRecipient
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The caller is not authorized for this validation path.
    /// @dev Error selector: `0x5c427cd9`
    error UnauthorizedCaller();

    /// @notice The session configuration or signature is invalid.
    /// @dev Error selector: `0x2def1a76`
    error InvalidSession();

    /// @notice The session has expired.
    /// @dev Error selector: `0x1fd05a4a`
    error SessionExpired();

    /// @notice The operation encoding is invalid.
    /// @dev Error selector: `0x398d4d32`
    error InvalidOperation();

    /// @notice The operation is outside the fixed funding policy.
    /// @dev Error selector: `0xe1d1c3b3`
    error FundingPolicyFailed();

    /// @notice The Permit2 claim is outside the fixed destination policy.
    /// @dev Error selector: `0xb5b02681`
    error ClaimPolicyFailed();

    /// @notice One field in the fixed Permit2 claim does not match the funding session.
    /// @dev Error selector: `0xe4de9307`
    error ClaimFieldMismatch(uint8 field);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param intentExecutor The Rhinestone IntentExecutor used by the Nexus.
    /// @param permit2 The Permit2 contract used by Rhinestone claims.
    constructor(address intentExecutor, address permit2) {
        if (intentExecutor == address(0) || permit2 == address(0)) {
            revert InvalidSession();
        }
        INTENT_EXECUTOR = intentExecutor;
        PERMIT2 = permit2;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Installs one fixed funding session for the calling Nexus.
    /// @param data ABI-encoded `SessionConfig`.
    function onInstall(bytes calldata data) external {
        if (_sessions[msg.sender].sessionKey != address(0)) {
            revert InvalidSession();
        }
        SessionConfig memory config = abi.decode(data, (SessionConfig));
        if (
            config.permissionId == bytes32(0) ||
            config.owner == address(0) ||
            config.sessionKey == address(0) ||
            config.sourceToken == address(0) ||
            config.destinationRecipient == address(0) ||
            config.destinationToken == address(0) ||
            config.arbiter == address(0) ||
            config.destinationChainId == 0 ||
            config.maxSourceAmount == 0 ||
            config.maxDestinationAmount == 0
        ) {
            revert InvalidSession();
        }
        if (config.validUntil <= block.timestamp) {
            revert SessionExpired();
        }
        _sessions[msg.sender] = config;
        emit SessionInstalled(
            msg.sender,
            config.permissionId,
            config.sessionKey,
            config.destinationRecipient
        );
    }

    /// @notice Removes the calling Nexus's funding session.
    /// @param data Unused uninstall data.
    function onUninstall(bytes calldata data) external {
        data;
        delete _sessions[msg.sender];
    }

    /// @notice Returns whether a Nexus has installed this validator.
    /// @param account The Nexus to inspect.
    /// @return Whether the Nexus has a session.
    function isInitialized(address account) external view returns (bool) {
        return _sessions[account].sessionKey != address(0);
    }

    /// @notice Returns a Nexus's installed funding session.
    /// @param account The Nexus to inspect.
    /// @return The installed configuration.
    function sessionConfig(address account) external view returns (SessionConfig memory) {
        return _sessions[account];
    }

    /// @notice Validates the session's Permit2 claim through the Nexus ERC-1271 path.
    /// @param sender The caller of `Nexus.isValidSignature`.
    /// @param hash The Permit2 typed-data digest.
    /// @param data The fixed claim signature and policy data.
    /// @return The ERC-1271 success value.
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata data)
        external
        view
        returns (bytes4)
    {
        if (sender != PERMIT2 && sender != INTENT_EXECUTOR) {
            revert UnauthorizedCaller();
        }
        SessionConfig storage config = _sessions[msg.sender];
        _validateFundingClaim(hash, data, config);
        return ERC1271_MAGICVALUE;
    }

    /// @notice Reports the permission as disabled so the SDK includes its reusable owner proof.
    /// @dev The validator does not store the owner authorization. Each claim must carry the same
    ///      standard multi-chain signature, so returning true here would let the SDK omit it.
    /// @param account Unused source Nexus address.
    /// @param permissionId Unused session permission identifier.
    /// @return Always false.
    function isPermissionEnabled(address account, bytes32 permissionId)
        external
        pure
        returns (bool)
    {
        account;
        permissionId;
        return false;
    }

    /// @notice Rejects the separate emissary-execution path.
    /// @dev Funding is valid only as part of the Permit2 claim checked by `isValidSignatureWithSender`.
    /// @param account Unused source Nexus address.
    /// @param digest Unused execution digest.
    /// @param data Unused validator data.
    /// @param operation Unused execution operation.
    /// @return This function always reverts.
    function verifyExecution(
        address account,
        bytes32 digest,
        bytes calldata data,
        Operation calldata operation
    )
        external
        pure
        returns (bytes4)
    {
        account;
        digest;
        data;
        operation;
        revert InvalidSession();
    }

    /// @notice Rejects ERC-4337 operations for this intent-only session.
    /// @param userOp Unused user operation.
    /// @param userOpHash Unused user operation hash.
    /// @return The ERC-4337 validation failure value.
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        pure
        returns (uint256)
    {
        userOp;
        userOpHash;
        return VALIDATION_FAILED;
    }

    /// @notice Returns whether this module is an ERC-7579 validator.
    /// @param moduleTypeId The module type to inspect.
    /// @return True only for the validator module type.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Loads and validates the installed session for a permission identifier.
    function _validateConfig(SessionConfig storage config, bytes32 permissionId) internal view {
        if (config.sessionKey == address(0) || config.permissionId != permissionId) {
            revert InvalidSession();
        }
        if (block.timestamp > config.validUntil) {
            revert SessionExpired();
        }
    }

    /// @dev Decodes and validates one fixed source funding envelope.
    function _validateFundingClaim(bytes32 hash, bytes calldata data, SessionConfig storage config)
        internal
        view
    {
        if (
            data.length <=
            FUNDING_SESSION_PREFIX_LENGTH + ECDSA_SIGNATURE_LENGTH + CLAIM_POLICY_DATA_LENGTH
        ) {
            revert InvalidSession();
        }

        bytes32 permissionId = bytes32(data[1:33]);
        _validateConfig(config, permissionId);
        if (data[0] != FUNDING_SESSION_MODE) {
            revert InvalidSession();
        }

        uint256 proofLength = uint32(bytes4(data[33:37]));
        uint256 proofEnd = FUNDING_SESSION_PREFIX_LENGTH + proofLength;
        uint256 operationOffset = proofEnd + ECDSA_SIGNATURE_LENGTH + CLAIM_POLICY_DATA_LENGTH;
        if (proofLength == 0 || operationOffset >= data.length) {
            revert InvalidSession();
        }
        FundingAuthorizationProof memory proof =
            abi.decode(data[FUNDING_SESSION_PREFIX_LENGTH:proofEnd], (FundingAuthorizationProof));
        _validateMultiChainAuthorization(msg.sender, config, permissionId, proof);
        _validateSignedPermit2Claim(hash, data, proofEnd, operationOffset, config);
    }

    /// @dev Checks the session signature, Permit2 claim, and matching source operation.
    function _validateSignedPermit2Claim(
        bytes32 hash,
        bytes calldata data,
        uint256 proofEnd,
        uint256 operationOffset,
        SessionConfig storage config
    )
        internal
        view
    {
        uint256 claimOffset = proofEnd + ECDSA_SIGNATURE_LENGTH;
        bytes32 accountBoundHash =
            MessageHashUtils.toEthSignedMessageHash(
                abi.encodePacked(bytes32(uint256(uint160(msg.sender))), hash)
            );
        if (_recover(accountBoundHash, data[proofEnd:claimOffset]) != config.sessionKey) {
            revert InvalidSession();
        }
        bytes calldata claimData = data[claimOffset:operationOffset];
        bytes calldata operationData = data[operationOffset:];
        uint256 claimSourceAmount = _validatePermit2Claim(hash, claimData, config);
        if (_operationHash(operationData) != _readWord(claimData, 314)) {
            revert ClaimFieldMismatch(10);
        }
        if (_validateFundingOperation(msg.sender, config, operationData) != claimSourceAmount) {
            revert FundingPolicyFailed();
        }
    }

    /// @dev Verifies the reusable owner signature and the selected chain session.
    function _validateMultiChainAuthorization(
        address account,
        SessionConfig storage config,
        bytes32 permissionId,
        FundingAuthorizationProof memory proof
    )
        internal
        view
    {
        uint256 count = proof.hashesAndChainIds.length;
        uint256 selectedIndex = proof.sessionToEnableIndex;
        if (count == 0 || selectedIndex >= count) {
            revert InvalidSession();
        }

        bytes32 salt = _fundingAuthorizationSalt(config);
        bytes memory validatorInitData = _sessionValidatorInitData(config.sessionKey);
        if (
            permissionId !=
            keccak256(abi.encode(OWNABLE_SESSION_VALIDATOR, validatorInitData, salt))
        ) {
            revert InvalidSession();
        }
        bytes32 signedSessionHash =
            keccak256(
                abi.encode(
                    SIGNED_SESSION_TYPEHASH,
                    account,
                    type(uint256).max,
                    uint256(0),
                    DEFAULT_SIGNED_PERMISSIONS_HASH,
                    salt,
                    OWNABLE_SESSION_VALIDATOR,
                    keccak256(validatorInitData),
                    SMART_SESSION_EMISSARY
                )
            );
        HashAndChainId memory selected = proof.hashesAndChainIds[selectedIndex];
        if (selected.chainId != block.chainid || selected.sessionDigest != signedSessionHash) {
            revert InvalidSession();
        }

        bytes32[] memory chainSessionHashes = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            HashAndChainId memory item = proof.hashesAndChainIds[i];
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
        if (_recoverParts(digest, proof.ownerR, proof.ownerS, proof.ownerV) != config.owner) {
            revert InvalidSession();
        }
    }

    /// @dev Hashes the fields fixed by one source funding session.
    function _fundingAuthorizationSalt(SessionConfig storage config)
        internal
        view
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    config.owner,
                    config.validUntil,
                    config.sourceToken,
                    config.destinationRecipient,
                    config.destinationToken,
                    config.arbiter,
                    config.destinationChainId,
                    config.maxSourceAmount,
                    config.maxDestinationAmount
                )
            );
    }

    /// @dev Validates the source calls and returns the amount pulled from the owner.
    function _validateFundingOperation(
        address account,
        SessionConfig storage config,
        bytes calldata operationData
    )
        internal
        view
        returns (uint256 totalPulled)
    {
        if (operationData.length < 32) {
            revert InvalidOperation();
        }
        bytes32 mode = bytes32(operationData[:32]);
        if (
            mode != ERC7579_ERC1271_MODE &&
            mode != ERC7579_EMISSARY_EXECUTION_MODE &&
            mode != ERC7579_ERC1271_EMISSARY_EXECUTION_MODE
        ) {
            revert InvalidOperation();
        }

        Execution[] memory executions = abi.decode(operationData[32:], (Execution[]));
        uint256 approvedAmount;
        uint256 approvalCount;
        uint256 permitCount;
        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            if (execution.target != config.sourceToken || execution.value != 0) {
                revert FundingPolicyFailed();
            }
            bytes4 selector = _selector(execution.callData);
            if (selector == IERC20.transferFrom.selector) {
                if (
                    _readAddress(execution.callData, 4) != config.owner ||
                    _readAddress(execution.callData, 36) != account
                ) {
                    revert FundingPolicyFailed();
                }
                totalPulled += _readUint(execution.callData, 68);
            } else if (selector == IERC20.approve.selector) {
                if (++approvalCount > 1 || _readAddress(execution.callData, 4) != PERMIT2) {
                    revert FundingPolicyFailed();
                }
                approvedAmount = _readUint(execution.callData, 36);
            } else if (selector == PERMIT_SELECTOR) {
                if (
                    ++permitCount > 1 ||
                    _readAddress(execution.callData, 4) != config.owner ||
                    _readAddress(execution.callData, 36) != account ||
                    _readUint(execution.callData, 68) > config.maxSourceAmount ||
                    _readUint(execution.callData, 100) > config.validUntil ||
                    _readUint(execution.callData, 100) < block.timestamp
                ) {
                    revert FundingPolicyFailed();
                }
            } else {
                revert FundingPolicyFailed();
            }
        }
        if (
            totalPulled == 0 ||
            totalPulled > config.maxSourceAmount ||
            (approvalCount == 1 && approvedAmount < totalPulled)
        ) {
            revert FundingPolicyFailed();
        }
    }

    /// @dev Validates the compact Permit2 claim and returns its source amount.
    function _validatePermit2Claim(
        bytes32 expectedDigest,
        bytes calldata data,
        SessionConfig storage config
    )
        internal
        view
        returns (uint256 sourceAmount)
    {
        if (data.length != CLAIM_POLICY_DATA_LENGTH) {
            revert ClaimPolicyFailed();
        }

        ClaimFields memory claim = _decodeAndValidateClaim(data, config);
        if (_permit2Digest(data, claim) != expectedDigest) {
            revert ClaimFieldMismatch(9);
        }
        return claim.sourceAmount;
    }

    /// @dev Decodes the route fields and checks them against the installed session.
    function _decodeAndValidateClaim(bytes calldata data, SessionConfig storage config)
        internal
        view
        returns (ClaimFields memory claim)
    {
        claim.spender = address(bytes20(data[0:20]));
        claim.nonce = uint256(bytes32(data[20:52]));
        claim.deadline = uint256(bytes32(data[52:84]));
        claim.sourceToken = address(uint160(uint256(_readWord(data, 85))));
        claim.sourceAmount = uint256(_readWord(data, 117));
        claim.recipient = address(bytes20(data[149:169]));
        claim.destinationChainId = uint256(_readWord(data, 169));
        claim.fillExpiry = uint256(_readWord(data, 201));
        claim.destinationToken = address(uint160(uint256(_readWord(data, 234))));
        claim.destinationAmount = uint256(_readWord(data, 266));

        if (claim.spender != config.arbiter)
            revert ClaimFieldMismatch(1);
        if (claim.deadline < block.timestamp || claim.deadline > config.validUntil)
            revert ClaimFieldMismatch(2);
        if (uint8(data[84]) != 1)
            revert ClaimFieldMismatch(3);
        if (
            claim.sourceToken != config.sourceToken ||
            claim.sourceAmount == 0 ||
            claim.sourceAmount > config.maxSourceAmount
        )
            revert ClaimFieldMismatch(4);
        if (claim.recipient != config.destinationRecipient)
            revert ClaimFieldMismatch(5);
        if (
            claim.destinationChainId != config.destinationChainId ||
            claim.fillExpiry < block.timestamp ||
            claim.fillExpiry > config.validUntil
        )
            revert ClaimFieldMismatch(6);
        if (uint8(data[233]) != 1)
            revert ClaimFieldMismatch(7);
        if (
            claim.destinationToken != config.destinationToken ||
            claim.destinationAmount == 0 ||
            claim.destinationAmount > config.maxDestinationAmount
        )
            revert ClaimFieldMismatch(8);
    }

    /// @dev Reconstructs the signed Permit2 witness digest.
    function _permit2Digest(bytes calldata data, ClaimFields memory claim)
        internal
        view
        returns (bytes32)
    {
        bytes32 tokenPermissionsHash =
            keccak256(
                abi.encodePacked(
                    keccak256(
                        abi.encode(TOKEN_PERMISSIONS_TYPEHASH, claim.sourceToken, claim.sourceAmount)
                    )
                )
            );
        bytes32 tokenOutHash =
            keccak256(
                abi.encodePacked(
                    keccak256(
                        abi.encode(TOKEN_TYPEHASH, claim.destinationToken, claim.destinationAmount)
                    )
                )
            );
        bytes32 targetHash =
            keccak256(
                abi.encode(
                    TARGET_TYPEHASH,
                    claim.recipient,
                    tokenOutHash,
                    claim.destinationChainId,
                    claim.fillExpiry
                )
            );
        uint128 minGas = uint128(bytes16(data[298:314]));
        bytes32 mandateHash =
            keccak256(
                abi.encode(
                    MANDATE_TYPEHASH,
                    targetHash,
                    minGas,
                    _readWord(data, 314),
                    _readWord(data, 346),
                    _readWord(data, 378)
                )
            );
        bytes32 permitHash =
            keccak256(
                abi.encode(
                    PERMIT_TYPEHASH,
                    tokenPermissionsHash,
                    claim.spender,
                    claim.nonce,
                    claim.deadline,
                    mandateHash
                )
            );
        bytes32 domainSeparator =
            keccak256(abi.encode(EIP712_DOMAIN_TYPEHASH, PERMIT2_NAME_HASH, block.chainid, PERMIT2));
        return MessageHashUtils.toTypedDataHash(domainSeparator, permitHash);
    }

    /// @dev Returns the standard one-of-one session-validator initialization data.
    function _sessionValidatorInitData(address sessionKey) internal pure returns (bytes memory) {
        address[] memory owners = new address[](1);
        owners[0] = sessionKey;
        return abi.encode(uint256(1), owners);
    }

    /// @dev Hashes an encoded ERC-7579 operation.
    function _operationHash(bytes calldata operationData) internal pure returns (bytes32) {
        if (operationData.length < 32) {
            revert InvalidOperation();
        }
        bytes32 mode = bytes32(operationData[:32]);
        Execution[] memory executions = abi.decode(operationData[32:], (Execution[]));
        bytes32[] memory executionHashes = new bytes32[](executions.length);
        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            executionHashes[i] = keccak256(
                abi.encode(
                    OPS_TYPEHASH,
                    execution.target,
                    execution.value,
                    keccak256(execution.callData)
                )
            );
        }
        return
            keccak256(abi.encode(OP_TYPEHASH, mode, keccak256(abi.encodePacked(executionHashes))));
    }

    /// @dev Reads a function selector from ABI call data.
    function _selector(bytes memory callData) internal pure returns (bytes4 selector) {
        if (callData.length < 4) {
            revert InvalidOperation();
        }
        assembly ("memory-safe") {
            selector := mload(add(callData, 0x20))
        }
    }

    /// @dev Reads an ABI-encoded address from memory.
    function _readAddress(bytes memory data, uint256 offset) internal pure returns (address value) {
        value = address(uint160(_readUint(data, offset)));
    }

    /// @dev Reads an ABI-encoded integer from memory.
    function _readUint(bytes memory data, uint256 offset) internal pure returns (uint256 value) {
        if (data.length < offset + 32) {
            revert InvalidOperation();
        }
        assembly ("memory-safe") {
            value := mload(add(add(data, 0x20), offset))
        }
    }

    /// @dev Reads a raw word from calldata.
    function _readWord(bytes calldata data, uint256 offset) internal pure returns (bytes32 value) {
        if (data.length < offset + 32) {
            revert ClaimPolicyFailed();
        }
        assembly ("memory-safe") {
            value := calldataload(add(data.offset, offset))
        }
    }

    /// @dev Recovers the signer from a 65-byte Rhinestone ECDSA signature.
    function _recover(bytes32 digest, bytes calldata signature)
        internal
        pure
        returns (address signer)
    {
        if (signature.length != 65) {
            revert InvalidSession();
        }
        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        return _recoverParts(digest, r, s, v);
    }

    /// @dev Recovers a Rhinestone ECDSA signature supplied as separate fields.
    function _recoverParts(bytes32 digest, bytes32 r, bytes32 s, uint8 v)
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
            revert InvalidSession();
        }
        ECDSA.RecoverError error;
        (signer, error, ) = ECDSA.tryRecover(digest, v, r, s);
        if (error != ECDSA.RecoverError.NoError) {
            revert InvalidSession();
        }
    }
}
