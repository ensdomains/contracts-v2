// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IValidator} from "nexus/interfaces/modules/IValidator.sol";
import {
    ERC1271_MAGICVALUE,
    MODULE_TYPE_VALIDATOR,
    VALIDATION_FAILED
} from "nexus/types/Constants.sol";

import {HCAExecutionLib} from "./libraries/HCAExecutionLib.sol";
import {HCAOperationHashLib} from "./libraries/HCAOperationHashLib.sol";
import {HCAPermit2Lib} from "./libraries/HCAPermit2Lib.sol";
import {HCASignatureLib} from "./libraries/HCASignatureLib.sol";
import {HCASmartSessionLib} from "./libraries/HCASmartSessionLib.sol";

/// @title Rhinestone Claim Router
/// @notice Resolves the active claim adapter for a route.
/// @dev Interface selector: `0x9e4ba7aa`
interface IRhinestoneClaimRouter {
    /// @notice Returns the claim adapter for a protocol version and function selector.
    /// @param version The route protocol version.
    /// @param selector The claim function selector.
    /// @return adapter The active claim adapter.
    /// @return adapterTag The adapter metadata tag.
    function getClaimAdapter(bytes2 version, bytes4 selector)
        external
        view
        returns (address adapter, bytes12 adapterTag);
}


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

    /// @dev Fixed source-session mode carrying the reusable multi-chain owner authorization.
    bytes1 internal constant FUNDING_SESSION_MODE = 0x04;

    /// @dev Size of the mode, permission ID, and four-byte authorization-proof length.
    uint256 internal constant FUNDING_SESSION_PREFIX_LENGTH = 37;

    /// @dev Size of the fixed signature and claim data following the authorization proof.
    uint256 internal constant FUNDING_SESSION_SUFFIX_LENGTH =
        HCASignatureLib.SIGNATURE_LENGTH + HCAPermit2Lib.CLAIM_DATA_LENGTH;

    /// @notice Rhinestone operation mode for ERC-1271 ERC-7579 execution.
    bytes32 public constant ERC7579_ERC1271_MODE = bytes32(uint256(0x0201) << 240);

    /// @notice Rhinestone operation mode for emissary ERC-7579 execution.
    bytes32 public constant ERC7579_EMISSARY_EXECUTION_MODE = bytes32(uint256(0x0204) << 240);

    /// @notice Rhinestone operation mode for ERC-1271 with emissary-execution fallback.
    bytes32 public constant ERC7579_ERC1271_EMISSARY_EXECUTION_MODE =
        bytes32(uint256(0x0206) << 240);

    /// @notice Rhinestone protocol version used by the supported Across claim.
    bytes2 public constant RHINESTONE_PROTOCOL_VERSION = 0x0001;

    /// @notice Function selector for the supported Permit2 Across claim.
    bytes4 public constant ACROSS_PERMIT2_CLAIM_SELECTOR = 0xc9df5e29;

    /// @notice The only executor allowed to present session operations.
    address public immutable INTENT_EXECUTOR;

    /// @notice The Permit2 contract that requests ERC-1271 claim validation.
    address public immutable PERMIT2;

    /// @notice The Rhinestone Router that resolves the active Across claim adapter.
    IRhinestoneClaimRouter public immutable ROUTER;

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
    /// @param router The Rhinestone Router that resolves the active claim adapter.
    constructor(address intentExecutor, address permit2, address router) {
        if (intentExecutor == address(0) || permit2 == address(0) || router == address(0)) {
            revert InvalidSession();
        }
        INTENT_EXECUTOR = intentExecutor;
        PERMIT2 = permit2;
        ROUTER = IRhinestoneClaimRouter(router);
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
        if (data.length <= FUNDING_SESSION_PREFIX_LENGTH + FUNDING_SESSION_SUFFIX_LENGTH) {
            revert InvalidSession();
        }

        bytes32 permissionId = bytes32(data[1:33]);
        _validateConfig(config, permissionId);
        if (data[0] != FUNDING_SESSION_MODE) {
            revert InvalidSession();
        }

        uint256 proofLength = uint32(bytes4(data[33:37]));
        uint256 proofEnd = FUNDING_SESSION_PREFIX_LENGTH + proofLength;
        uint256 operationOffset = proofEnd + FUNDING_SESSION_SUFFIX_LENGTH;
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
        uint256 claimOffset = proofEnd + HCASignatureLib.SIGNATURE_LENGTH;
        bytes32 accountBoundHash =
            MessageHashUtils.toEthSignedMessageHash(
                abi.encodePacked(bytes32(uint256(uint160(msg.sender))), hash)
            );
        if (
            HCASignatureLib.recover(accountBoundHash, data[proofEnd:claimOffset]) !=
            config.sessionKey
        ) {
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
        (bytes32 expectedPermissionId, bytes32 expectedSessionDigest) =
            HCASmartSessionLib.authorizationHashes(account, config.sessionKey, salt);
        if (permissionId != expectedPermissionId) {
            revert InvalidSession();
        }
        HashAndChainId memory selected = proof.hashesAndChainIds[selectedIndex];
        if (selected.chainId != block.chainid || selected.sessionDigest != expectedSessionDigest) {
            revert InvalidSession();
        }

        bytes32[] memory chainSessionHashes = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            HashAndChainId memory item = proof.hashesAndChainIds[i];
            chainSessionHashes[i] = HCASmartSessionLib.chainSessionHash(
                item.chainId,
                item.sessionDigest
            );
        }
        bytes32 digest = HCASmartSessionLib.multiChainDigest(chainSessionHashes);
        if (
            HCASignatureLib.recover(digest, proof.ownerR, proof.ownerS, proof.ownerV) !=
            config.owner
        ) {
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
        if (!HCAOperationHashLib.isSupportedMode(mode)) {
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
            } else if (selector == IERC20Permit.permit.selector) {
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
        if (data.length != HCAPermit2Lib.CLAIM_DATA_LENGTH) {
            revert ClaimPolicyFailed();
        }

        HCAPermit2Lib.Claim memory claim = _decodeAndValidateClaim(data, config);
        if (HCAPermit2Lib.digest(data, claim, block.chainid, PERMIT2) != expectedDigest) {
            revert ClaimFieldMismatch(9);
        }
        return claim.sourceAmount;
    }

    /// @dev Decodes the route fields and checks them against the installed session.
    function _decodeAndValidateClaim(bytes calldata data, SessionConfig storage config)
        internal
        view
        returns (HCAPermit2Lib.Claim memory claim)
    {
        claim = HCAPermit2Lib.decode(data);

        (address activeArbiter, ) =
            ROUTER.getClaimAdapter(RHINESTONE_PROTOCOL_VERSION, ACROSS_PERMIT2_CLAIM_SELECTOR);
        if (activeArbiter == address(0) || claim.spender != activeArbiter) {
            revert ClaimFieldMismatch(1);
        }
        if (claim.deadline < block.timestamp || claim.deadline > config.validUntil) {
            revert ClaimFieldMismatch(2);
        }
        if (uint8(data[84]) != 1) {
            revert ClaimFieldMismatch(3);
        }
        if (
            claim.sourceToken != config.sourceToken ||
            claim.sourceAmount == 0 ||
            claim.sourceAmount > config.maxSourceAmount
        ) {
            revert ClaimFieldMismatch(4);
        }
        if (claim.recipient != config.destinationRecipient) {
            revert ClaimFieldMismatch(5);
        }
        if (
            claim.targetChainId != config.destinationChainId ||
            claim.fillExpiry < block.timestamp ||
            claim.fillExpiry > config.validUntil
        ) {
            revert ClaimFieldMismatch(6);
        }
        if (uint8(data[233]) != 1) {
            revert ClaimFieldMismatch(7);
        }
        if (
            claim.tokenOut != config.destinationToken ||
            claim.amountOut == 0 ||
            claim.amountOut > config.maxDestinationAmount
        ) {
            revert ClaimFieldMismatch(8);
        }
    }

    /// @dev Hashes an encoded ERC-7579 operation.
    function _operationHash(bytes calldata operationData) internal pure returns (bytes32) {
        if (operationData.length < 32) {
            revert InvalidOperation();
        }
        return HCAOperationHashLib.hash(operationData);
    }

    /// @dev Reads a function selector from ABI call data.
    function _selector(bytes memory callData) internal pure returns (bytes4 selector) {
        if (callData.length < 4) {
            revert InvalidOperation();
        }
        return HCAExecutionLib.selector(callData);
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
        return HCAExecutionLib.readUint(data, offset);
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

    /// @dev Recovers a Rhinestone signature and maps malformed signatures to `InvalidSession`.
    function _recover(bytes32 digest, bytes calldata signature)
        internal
        pure
        returns (address signer)
    {
        signer = HCASignatureLib.recover(digest, signature);
        if (signer == address(0)) {
            revert InvalidSession();
        }
    }
}
