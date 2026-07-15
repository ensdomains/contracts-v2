// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IValidator} from "nexus/interfaces/modules/IValidator.sol";

import {IETHRegistrar} from "../registrar/interfaces/IETHRegistrar.sol";
import {IETHRenewer} from "../registrar/interfaces/IETHRenewer.sol";
import {PermissionedResolver} from "../resolver/PermissionedResolver.sol";
import {
    DefaultReverseRegistrarAdapter
} from "../reverse-registrar/DefaultReverseRegistrarAdapter.sol";

import {IStandaloneHCAOwner} from "./interfaces/IStandaloneHCAOwner.sol";

/// @title Owner-Bound Registration Session Validator
/// @notice Fixed validator for standalone-HCA owner authorization and ENS registration sessions.
/// @dev Owner signatures use Rhinestone's existing HCA format. Sessions are enabled by an
///      owner-authorized HCA call and consumed through Rhinestone's existing Smart Session USE
///      payload. The permission checks remain hardcoded here rather than in dynamic policy modules.
contract OwnerBoundRegistrationSessionValidator is IValidator {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice A single ERC-7579 execution.
    struct Execution {
        address target;
        uint256 value;
        bytes callData;
    }

    /// @notice Operation supplied by the IntentExecutor to an emissary verifier.
    struct Operation {
        bytes data;
    }

    /// @notice Compact configuration for one pre-enabled registration session.
    struct SessionConfig {
        address sessionKey;
        uint48 validUntil;
        address resolver;
        uint96 sessionNonce;
    }

    ////////////////////////////////////////////////////////////////////////
    // Constants & Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Standard ERC-1271 success return value.
    /// @dev Returned by ERC-1271 validators for valid signatures.
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;

    /// @notice ERC-7579 validator module type id.
    /// @dev Module type ID for validator modules.
    uint256 internal constant MODULE_TYPE_VALIDATOR = 1;

    /// @notice ERC-4337 validation failure value.
    /// @dev Returned from unsupported ERC-4337 validation.
    uint256 internal constant VALIDATION_FAILED = 1;

    /// @notice Smart Session payload mode for an already-enabled permission.
    bytes1 internal constant SMART_SESSION_MODE_USE = 0x00;

    /// @notice Existing Smart Session USE payload size for one ECDSA session signer.
    uint256 internal constant SMART_SESSION_USE_LENGTH = 98;

    /// @notice Rhinestone operation mode for pure emissary ERC-7579 execution.
    bytes32 public constant ERC7579_EMISSARY_EXECUTION_MODE = bytes32(uint256(0x0204) << 240);

    /// @notice Selector for ETHRegistrar.commit(bytes32).
    bytes4 public constant COMMIT_SELECTOR = IETHRegistrar.commit.selector;

    /// @notice Selector for ETHRegistrar.register(string,address,bytes32,address,address,uint64,address,bytes32).
    bytes4 public constant REGISTER_SELECTOR = IETHRegistrar.register.selector;

    /// @notice Selector for ETHRegistrar.renew(string,uint64,address,bytes32).
    bytes4 public constant RENEW_SELECTOR = IETHRenewer.renew.selector;

    /// @notice Selector for ERC20.approve(address,uint256).
    bytes4 public constant APPROVE_SELECTOR = IERC20.approve.selector;

    /// @notice Selector for VerifiableFactory.deployProxy(address,uint256,bytes).
    bytes4 public constant DEPLOY_PROXY_SELECTOR = IVerifiableFactory.deployProxy.selector;

    /// @notice Selector for DefaultReverseRegistrarAdapter.setNameWithHCA(address,string).
    bytes4 public constant SET_NAME_WITH_HCA_SELECTOR =
        DefaultReverseRegistrarAdapter.setNameWithHCA.selector;

    /// @notice Selector for PermissionedResolver.clearRecords(bytes32).
    bytes4 public constant CLEAR_RECORDS_SELECTOR = 0x3603d758;

    /// @notice Selector for PermissionedResolver.setABI(bytes32,uint256,bytes).
    bytes4 public constant SET_ABI_SELECTOR = 0x623195b0;

    /// @notice Selector for PermissionedResolver.setAddr(bytes32,address).
    bytes4 public constant SET_ADDR_SELECTOR = 0xd5fa2b00;

    /// @notice Selector for PermissionedResolver.setAddr(bytes32,uint256,bytes).
    bytes4 public constant SET_ADDR_COIN_TYPE_SELECTOR = 0x8b95dd71;

    /// @notice Selector for PermissionedResolver.setContenthash(bytes32,bytes).
    bytes4 public constant SET_CONTENTHASH_SELECTOR = 0x304e6ade;

    /// @notice Selector for PermissionedResolver.setData(bytes32,string,bytes).
    bytes4 public constant SET_DATA_SELECTOR = 0x4eb9c45e;

    /// @notice Selector for PermissionedResolver.setInterface(bytes32,bytes4,address).
    bytes4 public constant SET_INTERFACE_SELECTOR = 0xe59d895d;

    /// @notice Selector for PermissionedResolver.setPubkey(bytes32,bytes32,bytes32).
    bytes4 public constant SET_PUBKEY_SELECTOR = 0x29cd62ea;

    /// @notice Selector for PermissionedResolver.setText(bytes32,string,string).
    bytes4 public constant SET_TEXT_SELECTOR = 0x10f13a8c;

    /// @notice Selector for PermissionedResolver.setName(bytes32,string).
    bytes4 public constant SET_NAME_SELECTOR = 0x77372213;

    /// @notice Selector for PermissionedResolver.multicall(bytes[]).
    bytes4 public constant MULTICALL_SELECTOR = 0xac9650d8;

    /// @notice Selector for PermissionedResolver.multicallWithNodeCheck(bytes32,bytes[]).
    bytes4 public constant MULTICALL_WITH_NODE_CHECK_SELECTOR = 0xe32954eb;

    /// @notice Selector for PermissionedResolver.authorizeNameRoles(bytes,uint256,address,bool).
    bytes4 public constant AUTHORIZE_NAME_ROLES_SELECTOR =
        PermissionedResolver.authorizeNameRoles.selector;

    /// @notice The HCA-aware default reverse registrar adapter permitted for default primary-name setup.
    address public immutable DEFAULT_REVERSE_REGISTRAR_HCA_ADAPTER;

    /// @notice The resolver implementation permitted for resolver deployment.
    address public immutable PERMITTED_RESOLVER_IMPL;

    /// @notice The ENS registrar permitted for registration actions.
    address public immutable ETH_REGISTRAR;

    /// @notice The VerifiableFactory permitted for resolver deployment.
    address public immutable VERIFIABLE_FACTORY;

    /// @notice The primary ERC20 payment token accepted by the registration policy.
    address public immutable PAYMENT_TOKEN;

    /// @notice The secondary ERC20 payment token accepted by the registration policy.
    address public immutable SECONDARY_PAYMENT_TOKEN;

    /// @notice The only executor allowed to present session operations for verification.
    address public immutable INTENT_EXECUTOR;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    mapping(address account => mapping(bytes32 permissionId => SessionConfig config)) internal _sessions;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event SessionEnabled(
        address indexed account,
        bytes32 indexed permissionId,
        address indexed sessionKey,
        address resolver,
        uint48 validUntil,
        uint96 sessionNonce
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Operation data is not an ERC-7579 operation payload.
    /// @dev Error selector: `0xf679d4db`
    error InvalidOperationEncoding();

    /// @notice A supplied signer did not match the HCA owner or session key.
    /// @dev Error selector: `0x815e1d64`
    error InvalidSigner();

    /// @notice The HCA did not expose an owner.
    /// @dev Error selector: `0xbff8a462`
    error OwnerUnavailable();

    /// @notice The session has expired.
    /// @dev Error selector: `0x1fd05a4a`
    error SessionExpired();

    /// @notice A session was presented by an address other than the fixed IntentExecutor.
    error CallerNotIntentExecutor();

    /// @notice A session payload is not the supported Smart Session USE form.
    error InvalidSessionData();

    /// @notice A target/action pair is outside the hardcoded registration policy.
    /// @param target The forbidden execution target.
    /// @param selector The forbidden function selector.
    /// @dev Error selector: `0xde1834f2`
    error ActionNotAllowed(address target, bytes4 selector);

    /// @notice One of the hardcoded policy argument checks failed.
    /// @dev Error selector: `0xe50c42ea`
    error PolicyRuleFailed();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param defaultReverseRegistrarHcaAdapter The HCA-aware default reverse registrar adapter.
    /// @param permittedResolverImpl The resolver implementation accepted in resolver deployment actions.
    /// @param ethRegistrar The ENS registrar accepted by the registration policy.
    /// @param verifiableFactory The VerifiableFactory accepted by the registration policy.
    /// @param paymentToken The primary ERC20 payment token accepted by the registration policy.
    /// @param secondaryPaymentToken The secondary ERC20 payment token accepted by the registration policy.
    /// @param intentExecutor The fixed IntentExecutor that supplies operations to `verifyExecution`.
    constructor(
        address defaultReverseRegistrarHcaAdapter,
        address permittedResolverImpl,
        address ethRegistrar,
        address verifiableFactory,
        address paymentToken,
        address secondaryPaymentToken,
        address intentExecutor
    )
    {
        DEFAULT_REVERSE_REGISTRAR_HCA_ADAPTER = defaultReverseRegistrarHcaAdapter;
        PERMITTED_RESOLVER_IMPL = permittedResolverImpl;
        ETH_REGISTRAR = ethRegistrar;
        VERIFIABLE_FACTORY = verifiableFactory;
        PAYMENT_TOKEN = paymentToken;
        SECONDARY_PAYMENT_TOKEN = secondaryPaymentToken;
        INTENT_EXECUTOR = intentExecutor;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Validates an existing Rhinestone HCA owner signature.
    /// @param sender The caller forwarded by the account.
    /// @param hash The digest supplied by the intent executor.
    /// @param data A single 65-byte owner signature.
    /// @return magicValue ERC-1271 success value.
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata data)
        external
        view
        returns (bytes4 magicValue)
    {
        if (sender != INTENT_EXECUTOR) {
            revert CallerNotIntentExecutor();
        }
        (address expectedOwner, ) = _ownerAndSessionNonce(msg.sender);
        if (_recover(hash, data) != expectedOwner) {
            revert InvalidSigner();
        }
        return ERC1271_MAGICVALUE;
    }

    /// @notice Enables one fixed-policy session through an owner-authorized HCA execution.
    /// @dev `msg.sender` is the HCA, so the enable call can be batched with its first owner-signed
    ///      intent. `permissionId` is the ID used by Rhinestone's existing session USE payload.
    function enableSession(
        bytes32 permissionId,
        address sessionKey,
        uint48 validUntil,
        address resolver
    )
        external
    {
        if (sessionKey == address(0)) {
            revert InvalidSigner();
        }
        if (validUntil < block.timestamp) {
            revert SessionExpired();
        }
        (, uint96 sessionNonce) = _ownerAndSessionNonce(msg.sender);
        _sessions[msg.sender][permissionId] = SessionConfig({sessionKey: sessionKey, validUntil: validUntil, resolver: resolver, sessionNonce: sessionNonce});
        emit SessionEnabled(msg.sender, permissionId, sessionKey, resolver, validUntil, sessionNonce);
    }

    /// @notice Returns whether a fixed-policy session is currently usable.
    function isPermissionEnabled(address account, bytes32 permissionId)
        external
        view
        returns (bool)
    {
        SessionConfig memory config = _sessions[account][permissionId];
        if (config.sessionKey == address(0) || block.timestamp > config.validUntil) {
            return false;
        }
        try IStandaloneHCAOwner(account).ownerAndSessionNonce() returns (
            address owner_,
            uint96 sessionNonce
        ) {
            return owner_ != address(0) && sessionNonce == config.sessionNonce;
        } catch {
            return false;
        }
    }

    /// @notice Verifies an existing Smart Session USE payload against the fixed ENS policy.
    /// @dev The fixed IntentExecutor supplies the actual operation. Only the compact USE mode is
    ///      supported; session enablement is an ordinary owner-authorized HCA call.
    function verifyExecution(
        address account,
        bytes32 digest,
        bytes calldata data,
        Operation calldata operation
    )
        external
        view
        returns (bytes4)
    {
        if (msg.sender != INTENT_EXECUTOR) {
            revert CallerNotIntentExecutor();
        }
        if (data.length != SMART_SESSION_USE_LENGTH || data[0] != SMART_SESSION_MODE_USE) {
            revert InvalidSessionData();
        }

        bytes32 permissionId = bytes32(data[1:33]);
        SessionConfig memory config = _sessions[account][permissionId];
        if (config.sessionKey == address(0)) {
            revert InvalidSigner();
        }
        if (block.timestamp > config.validUntil) {
            revert SessionExpired();
        }

        (address owner_, uint96 sessionNonce) = _ownerAndSessionNonce(account);
        if (sessionNonce != config.sessionNonce) {
            revert InvalidSigner();
        }
        if (_recover(digest, data[33:]) != config.sessionKey) {
            revert InvalidSigner();
        }

        _checkRegistrationPolicy(owner_, config.resolver, operation.data);
        return this.verifyExecution.selector;
    }

    /// @notice Rejects ERC-4337 validation for this validator.
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

    /// @notice Returns whether this module is a validator.
    /// @param moduleTypeId The ERC-7579 module type id.
    /// @return True when the module type is validator.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_VALIDATOR;
    }

    /// @notice Returns whether this fixed module is available for an account.
    /// @param account Unused account address.
    /// @return Always true because the module is fixed by the HCA implementation.
    function isInitialized(address account) external pure returns (bool) {
        account;

        return true;
    }

    /// @notice No-op install hook for ERC-7579 compatibility.
    /// @param data Unused install data.
    function onInstall(bytes calldata data) external pure {
        data;
    }

    /// @notice No-op uninstall hook for ERC-7579 compatibility.
    /// @param data Unused uninstall data.
    function onUninstall(bytes calldata data) external pure {
        data;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    function _ownerAndSessionNonce(address account)
        internal
        view
        returns (address owner_, uint96 sessionNonce)
    {
        try IStandaloneHCAOwner(account).ownerAndSessionNonce() returns (
            address owner__,
            uint96 sessionNonce_
        ) {
            owner_ = owner__;
            sessionNonce = sessionNonce_;
        } catch {
            revert OwnerUnavailable();
        }
        if (owner_ == address(0)) {
            revert OwnerUnavailable();
        }
    }

    /// @notice Validates every execution against the hardcoded registration and name-management action set.
    /// @dev Checks target, selector, value, and selected ABI arguments for each execution.
    ///      A default reverse name may be updated in a standalone operation when the policy has a
    ///      nonzero resolver and the named account is the HCA owner. When registration shares the
    ///      batch, the default reverse name must match the registered name.
    /// @param owner The owner recorded for the HCA.
    /// @param allowedResolver The resolver bound to the enabled session.
    /// @param operationData The encoded ERC-7579 operation payload.
    function _checkRegistrationPolicy(
        address owner,
        address allowedResolver,
        bytes calldata operationData
    )
        internal
        view
    {
        if (
            operationData.length < 32 ||
            bytes32(operationData[:32]) != ERC7579_EMISSARY_EXECUTION_MODE
        ) {
            revert InvalidOperationEncoding();
        }

        Execution[] memory executions = abi.decode(operationData[32:], (Execution[]));
        bool seenRegister;
        address registeredResolver;
        bytes32 registeredNameHash;

        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            if (
                execution.target == ETH_REGISTRAR &&
                _selector(execution.callData) == REGISTER_SELECTOR
            ) {
                (bytes32 nameHash, address registrant, address resolver) =
                    _registerFields(execution.callData);
                if (registrant != owner) {
                    revert PolicyRuleFailed();
                }
                if (!seenRegister) {
                    seenRegister = true;
                    registeredResolver = resolver;
                    registeredNameHash = nameHash;
                } else if (registeredResolver != resolver || registeredNameHash != nameHash) {
                    revert PolicyRuleFailed();
                }
            }
        }

        if (
            allowedResolver != address(0) &&
            registeredResolver != address(0) &&
            allowedResolver != registeredResolver
        ) {
            revert PolicyRuleFailed();
        }
        address policyResolver = registeredResolver == address(0)
            ? allowedResolver
            : registeredResolver;

        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            if (execution.value != 0) {
                revert PolicyRuleFailed();
            }

            bytes4 selector = _selector(execution.callData);

            if (execution.target == ETH_REGISTRAR) {
                if (
                    selector != COMMIT_SELECTOR &&
                    selector != REGISTER_SELECTOR &&
                    selector != RENEW_SELECTOR
                ) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                continue;
            }

            if (policyResolver != address(0) && execution.target == policyResolver) {
                _checkResolverCall(execution.callData, owner);
                continue;
            }

            if (execution.target == DEFAULT_REVERSE_REGISTRAR_HCA_ADAPTER) {
                if (selector != SET_NAME_WITH_HCA_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                if (policyResolver == address(0)) {
                    revert PolicyRuleFailed();
                }
                (address account, bytes32 nameHash) = _defaultReverseFields(execution.callData);
                if (account != owner) {
                    revert PolicyRuleFailed();
                }
                if (seenRegister && nameHash != registeredNameHash) {
                    revert PolicyRuleFailed();
                }
                continue;
            }

            if (execution.target == PAYMENT_TOKEN || execution.target == SECONDARY_PAYMENT_TOKEN) {
                if (selector != APPROVE_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                _requireArgAddress(execution.callData, 4, ETH_REGISTRAR);
                continue;
            }

            if (execution.target == VERIFIABLE_FACTORY) {
                if (selector != DEPLOY_PROXY_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                _requireArgAddress(execution.callData, 4, PERMITTED_RESOLVER_IMPL);
                continue;
            }

            revert ActionNotAllowed(execution.target, selector);
        }
    }

    /// @notice Reads a function selector from calldata.
    /// @dev Reverts when calldata is shorter than a selector.
    /// @param callData ABI-encoded call data.
    /// @return selector_ The function selector.
    function _selector(bytes memory callData) internal pure returns (bytes4 selector_) {
        if (callData.length < 4) {
            revert InvalidOperationEncoding();
        }
        assembly ("memory-safe") {
            selector_ := mload(add(callData, 0x20))
        }
    }

    /// @notice Validates resolver record writes on the owner-authorized resolver.
    /// @dev Allows known resolver setters directly or recursively through supported multicalls,
    ///      plus `authorizeNameRoles` restricted to the owner as grantee. The role bitmap and
    ///      grant flag are not constrained here.
    /// @param callData ABI-encoded resolver call data.
    /// @param owner The owner recorded for the HCA.
    function _checkResolverCall(bytes memory callData, address owner) internal pure {
        bytes4 selector = _selector(callData);
        if (selector == MULTICALL_SELECTOR) {
            bytes[] memory calls = abi.decode(_callArgs(callData), (bytes[]));
            _checkResolverCalls(calls, owner);
            return;
        }
        if (selector == MULTICALL_WITH_NODE_CHECK_SELECTOR) {
            (, bytes[] memory calls) = abi.decode(_callArgs(callData), (bytes32, bytes[]));
            _checkResolverCalls(calls, owner);
            return;
        }
        if (selector == AUTHORIZE_NAME_ROLES_SELECTOR) {
            // authorizeNameRoles(bytes toName, uint256 roleBitmap, address account, bool grant):
            // the account head word sits after the toName offset and roleBitmap words.
            _requireArgAddress(callData, 4 + 64, owner);
            return;
        }
        if (_isResolverRecordSelector(selector)) {
            return;
        }
        revert ActionNotAllowed(address(0), selector);
    }

    /// @notice Validates nested resolver calls.
    /// @dev Recursively validates each encoded resolver call.
    /// @param calls ABI-encoded resolver calls.
    /// @param owner The owner recorded for the HCA.
    function _checkResolverCalls(bytes[] memory calls, address owner) internal pure {
        for (uint256 i; i < calls.length; ++i) {
            _checkResolverCall(calls[i], owner);
        }
    }

    /// @notice Reads the fields relevant to the registration policy from a register call.
    /// @dev Reads only the needed ABI head words and hashes `<label>.eth` in place instead of
    ///      decoding the full register tuple.
    /// @param callData ABI-encoded register call data.
    /// @return nameHash The keccak256 hash of the registered `<label>.eth` name.
    /// @return registrant The owner argument of the register call.
    /// @return resolver The resolver argument of the register call.
    function _registerFields(bytes memory callData)
        internal
        pure
        returns (bytes32 nameHash, address registrant, address resolver)
    {
        registrant = _readAddress(callData, 4 + 32);
        resolver = _readAddress(callData, 4 + 128);
        nameHash = _hashStringArg(callData, _readUint(callData, 4), true);
    }

    /// @notice Reads the fields relevant to the default reverse policy from a setNameWithHCA call.
    /// @dev Reads the account head word and hashes the name argument in place.
    /// @param callData ABI-encoded setNameWithHCA call data.
    /// @return account The account argument of the call.
    /// @return nameHash The keccak256 hash of the name argument.
    function _defaultReverseFields(bytes memory callData)
        internal
        pure
        returns (address account, bytes32 nameHash)
    {
        account = _readAddress(callData, 4);
        nameHash = _hashStringArg(callData, _readUint(callData, 4 + 32), false);
    }

    /// @notice Hashes a string argument read directly out of ABI call data.
    /// @dev Copies only the string bytes (plus the optional `.eth` suffix) before hashing,
    ///      avoiding a full-tuple decode. Reverts with `InvalidOperationEncoding` when the
    ///      encoded string does not fit the call data.
    /// @param callData ABI-encoded call data with a function selector prefix.
    /// @param argsOffset Offset of the string head relative to the start of the arguments.
    /// @param appendEthSuffix Whether to append `.eth` before hashing.
    /// @return result The keccak256 hash of the (suffixed) string bytes.
    function _hashStringArg(bytes memory callData, uint256 argsOffset, bool appendEthSuffix)
        internal
        pure
        returns (bytes32 result)
    {
        if (argsOffset > callData.length) {
            revert InvalidOperationEncoding();
        }
        uint256 lengthPos = 4 + argsOffset;
        uint256 stringLength = _readUint(callData, lengthPos);
        if (stringLength > callData.length || callData.length < lengthPos + 32 + stringLength) {
            revert InvalidOperationEncoding();
        }
        uint256 suffixLength = appendEthSuffix ? 4 : 0;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(0x40, add(ptr, and(add(add(stringLength, suffixLength), 0x3f), not(0x1f))))
            let src := add(add(callData, 0x20), add(lengthPos, 32))
            for { let i := 0 } lt(i, stringLength) { i := add(i, 0x20) } {
                mstore(add(ptr, i), mload(add(src, i)))
            }
            if suffixLength {
                mstore(add(ptr, stringLength), shl(224, 0x2e657468))
            }
            result := keccak256(ptr, add(stringLength, suffixLength))
        }
    }

    /// @notice Returns whether a selector is a resolver record setter.
    /// @dev Used by `_checkResolverCall` for direct and multicall resolver writes.
    /// @param selector_ The function selector.
    /// @return True when the selector is permitted by the resolver-write policy.
    function _isResolverRecordSelector(bytes4 selector_) internal pure returns (bool) {
        return
            selector_ == CLEAR_RECORDS_SELECTOR ||
            selector_ == SET_ABI_SELECTOR ||
            selector_ == SET_ADDR_SELECTOR ||
            selector_ == SET_ADDR_COIN_TYPE_SELECTOR ||
            selector_ == SET_CONTENTHASH_SELECTOR ||
            selector_ == SET_DATA_SELECTOR ||
            selector_ == SET_INTERFACE_SELECTOR ||
            selector_ == SET_PUBKEY_SELECTOR ||
            selector_ == SET_NAME_SELECTOR ||
            selector_ == SET_TEXT_SELECTOR;
    }

    /// @notice Copies function arguments out of ABI calldata bytes.
    /// @dev Drops the four-byte function selector and returns ABI-encoded arguments.
    /// @param callData ABI-encoded call data with a function selector prefix.
    /// @return args ABI-encoded function arguments.
    function _callArgs(bytes memory callData) internal pure returns (bytes memory args) {
        if (callData.length < 4) {
            revert InvalidOperationEncoding();
        }
        args = new bytes(callData.length - 4);
        for (uint256 i; i < args.length; ++i) {
            args[i] = callData[i + 4];
        }
    }

    /// @notice Reads an ABI-encoded address argument from calldata.
    /// @dev Reads and masks a 32-byte ABI word as an address.
    /// @param callData ABI-encoded call data.
    /// @param offset Offset of the ABI word to read.
    /// @return result The decoded address.
    function _readAddress(bytes memory callData, uint256 offset)
        internal
        pure
        returns (address result)
    {
        if (callData.length < offset + 32) {
            revert InvalidOperationEncoding();
        }
        assembly ("memory-safe") {
            result := and(mload(add(add(callData, 0x20), offset)), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    /// @notice Requires an ABI address argument to match the policy-expected address.
    /// @dev Reverts with `PolicyRuleFailed` on mismatch.
    /// @param callData ABI-encoded call data.
    /// @param offset Offset of the ABI word holding the address.
    /// @param expected The only address the policy accepts at that position.
    function _requireArgAddress(bytes memory callData, uint256 offset, address expected)
        internal
        pure
    {
        if (_readAddress(callData, offset) != expected) {
            revert PolicyRuleFailed();
        }
    }

    /// @notice Reads a raw 32-byte ABI word from calldata bytes.
    /// @dev Reverts when calldata is shorter than the requested word.
    /// @param callData ABI-encoded call data.
    /// @param offset Offset of the ABI word to read.
    /// @return result The word as a uint256.
    function _readUint(bytes memory callData, uint256 offset)
        internal
        pure
        returns (uint256 result)
    {
        if (callData.length < offset + 32) {
            revert InvalidOperationEncoding();
        }
        assembly ("memory-safe") {
            result := mload(add(add(callData, 0x20), offset))
        }
    }

    /// @notice Recovers the signer of an existing Rhinestone 65-byte ECDSA signature.
    /// @dev Values 31/32 select EIP-191 wrapping, matching Rhinestone's Ownable/ENS format.
    ///      Values 0/1 and 27/28 recover the supplied digest directly.
    /// @param digest The signed digest.
    /// @param signature The ECDSA signature.
    /// @return signer The recovered signer.
    function _recover(bytes32 digest, bytes calldata signature)
        internal
        pure
        returns (address signer)
    {
        if (signature.length != 65) {
            revert InvalidSigner();
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }
        if (v == 31 || v == 32) {
            digest = MessageHashUtils.toEthSignedMessageHash(digest);
            v -= 4;
        } else if (v < 27) {
            v += 27;
        }
        if (v != 27 && v != 28) {
            revert InvalidSigner();
        }
        ECDSA.RecoverError error;
        (signer, error, ) = ECDSA.tryRecover(digest, v, r, s);
        if (error != ECDSA.RecoverError.NoError) {
            revert InvalidSigner();
        }
    }
}
