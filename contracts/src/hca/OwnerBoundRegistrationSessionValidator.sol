// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

import {IStandaloneHCAOwner} from "./interfaces/IStandaloneHCAOwner.sol";

/// @title Owner-Bound Registration Session Validator
/// @notice Stateless validator for deferred ENS registrations executed by standalone HCAs.
/// @dev A valid signature is either a direct owner signature over the executor digest, or an
///      owner-signed session grant plus a session-key signature over the executor digest. Session
///      grants are bound to the resolver that may receive registration and resolver-record writes.
contract OwnerBoundRegistrationSessionValidator {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice A single ERC-7579 execution.
    struct Execution {
        address target;
        uint256 value;
        bytes callData;
    }

    /// @notice Signature envelope consumed after the validator-address ERC-1271 prefix.
    struct SignatureData {
        address owner;
        address sessionKey;
        uint48 validUntil;
        address resolver;
        uint256 permit2SourceChainId;
        address permit2Contract;
        address permit2Arbiter;
        uint256 permit2Nonce;
        uint256 permit2Expires;
        bytes ownerSignature;
        bytes sessionSignature;
        bytes operationData;
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

    /// @notice Selector for ETHRegistrar.commit(bytes32).
    bytes4 public constant COMMIT_SELECTOR = 0xf14fcbc8;

    /// @notice Selector for ETHRegistrar.register(string,address,bytes32,address,address,uint64,address,bytes32).
    bytes4 public constant REGISTER_SELECTOR = 0xcff3e7c2;

    /// @notice Selector for ETHRegistrar.renew(string,uint64,address).
    bytes4 public constant RENEW_SELECTOR = 0x545064a7;

    /// @notice Selector for ERC20.approve(address,uint256).
    bytes4 public constant APPROVE_SELECTOR = 0x095ea7b3;

    /// @notice Selector for VerifiableFactory.deployProxy(address,uint256,bytes).
    bytes4 public constant DEPLOY_PROXY_SELECTOR = 0x5d84121a;

    /// @notice Selector for ReverseRegistrarAdapter.claimWithHCA(address,address).
    bytes4 public constant CLAIM_WITH_HCA_SELECTOR = 0xc90695df;

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

    /// @notice Hash for the owner-signed stateless session grant.
    /// @dev Type hash for `RegistrationSessionGrant`.
    bytes32 internal constant SESSION_GRANT_TYPEHASH =
        keccak256(
            "RegistrationSessionGrant(uint256 chainId,address hca,address owner,address sessionKey,uint48 validUntil,address resolver)"
        );

    /// @notice Hash for a Permit2-shaped registration session grant.
    /// @dev This is the validator's session-grant payload carried by the JIT Permit2 witness.
    bytes32 internal constant PERMIT2_SESSION_GRANT_TYPEHASH =
        keccak256(
            "RegistrationPermit2SessionGrant(uint256 destinationChainId,address hca,address owner,address sessionKey,uint48 validUntil,address resolver)"
        );

    /// @notice Permit2 EIP-712 domain type hash used by the Rhinestone IntentExecutor.
    /// @dev Hash of `EIP712Domain(string name,uint256 chainId,address verifyingContract)`.
    bytes32 internal constant PERMIT2_DOMAIN_TYPEHASH =
        0x8cad95687ba82c2ce50e74f7b754645e5117c3a5bec8151c0726d5857980a866;

    /// @notice Permit2 EIP-712 domain name hash.
    /// @dev Hash of `Permit2`.
    bytes32 internal constant PERMIT2_NAME_HASH =
        0x9ac997416e8ff9d2ff6bebeb7149f65cdae5e32e2b90440b566bb3044041d36a;

    /// @notice Rhinestone JIT Permit2 intent type hash.
    /// @dev Hash of the JIT Permit2 intent struct used by the IntentExecutor.
    bytes32 internal constant PERMIT2_JIT_TYPEHASH =
        0x1b355fbc76f14a5aefe5c85df793a0f876f90d66f457273501c13ac311b5f3f8;

    /// @notice Rhinestone mandate type hash.
    /// @dev Hash of the mandate struct embedded in the JIT Permit2 witness.
    bytes32 internal constant PERMIT2_MANDATE_TYPEHASH =
        0xc988b4da10503879cf4b893fed09620229f5ade301ef5e4af6124b22823627dc;

    /// @notice Hash for an empty dynamic array.
    /// @dev Used by the Rhinestone Permit2 witness for empty token inputs.
    bytes32 internal constant EMPTY_ARRAY_HASH =
        0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

    /// @notice Hash for no destination operations in Rhinestone mandates.
    /// @dev Constant used by the IntentExecutor for empty destination operations.
    bytes32 internal constant NO_OPS_HASH =
        0x0c7bea50822ae8a3846eccbda4961a80e1e08aa92f2bf046be0011514ad2ddf1;

    /// @notice The HCA-aware reverse registrar adapter permitted for primary-name setup.
    address public immutable REVERSE_REGISTRAR_HCA_ADAPTER;

    /// @notice The resolver implementation permitted for resolver deployment.
    address public immutable PERMITTED_RESOLVER_IMPL;

    /// @notice The ENS registrar permitted for registration actions.
    address public immutable ETH_REGISTRAR;

    /// @notice The VerifiableFactory permitted for resolver deployment.
    address public immutable VERIFIABLE_FACTORY;

    /// @notice The mock USDC accepted by the registration policy.
    address public immutable MOCK_USDC;

    /// @notice The mock DAI accepted by the registration policy.
    address public immutable MOCK_DAI;

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

    /// @notice The owner grant has expired.
    /// @dev Error selector: `0x1fd05a4a`
    error SessionExpired();

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

    /// @param reverseRegistrarHcaAdapter The HCA-aware reverse registrar adapter.
    /// @param permittedResolverImpl The resolver implementation accepted in resolver deployment actions.
    /// @param ethRegistrar The ENS registrar accepted by the registration policy.
    /// @param verifiableFactory The VerifiableFactory accepted by the registration policy.
    /// @param mockUsdc The mock USDC token accepted by the registration policy.
    /// @param mockDai The mock DAI token accepted by the registration policy.
    constructor(
        address reverseRegistrarHcaAdapter,
        address permittedResolverImpl,
        address ethRegistrar,
        address verifiableFactory,
        address mockUsdc,
        address mockDai
    )
    {
        REVERSE_REGISTRAR_HCA_ADAPTER = reverseRegistrarHcaAdapter;
        PERMITTED_RESOLVER_IMPL = permittedResolverImpl;
        ETH_REGISTRAR = ethRegistrar;
        VERIFIABLE_FACTORY = verifiableFactory;
        MOCK_USDC = mockUsdc;
        MOCK_DAI = mockDai;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Validates a registration intent signature for the calling standalone HCA.
    /// @param sender The caller forwarded by the account.
    /// @param hash The digest supplied by the intent executor.
    /// @param data The encoded signature envelope.
    /// @return magicValue ERC-1271 success value.
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata data)
        external
        view
        returns (bytes4 magicValue)
    {
        sender;

        SignatureData calldata sigData;
        assembly ("memory-safe") {
            sigData := data.offset
        }

        address hca = msg.sender;
        address expectedOwner;
        try IStandaloneHCAOwner(hca).owner() returns (address owner_) {
            expectedOwner = owner_;
        } catch {
            revert OwnerUnavailable();
        }
        if (expectedOwner == address(0)) {
            revert OwnerUnavailable();
        }
        if (sigData.owner != expectedOwner) {
            revert InvalidSigner();
        }

        if (sigData.sessionKey == address(0)) {
            if (_recover(hash, sigData.ownerSignature) != sigData.owner) {
                revert InvalidSigner();
            }
        } else {
            if (block.timestamp > sigData.validUntil) {
                revert SessionExpired();
            }
            if (sigData.permit2Contract == address(0)) {
                bytes32 grantHash =
                    _registrationSessionGrantHash(
                        hca,
                        sigData.owner,
                        sigData.sessionKey,
                        sigData.validUntil,
                        sigData.resolver
                    );
                if (
                    _recover(_toEthSignedMessageHash(grantHash), sigData.ownerSignature) !=
                    sigData.owner
                ) {
                    revert InvalidSigner();
                }
            } else {
                if (block.timestamp > sigData.permit2Expires) {
                    revert SessionExpired();
                }
                bytes32 permit2Digest =
                    _permit2SessionDigest(
                        hca,
                        sigData.owner,
                        sigData.sessionKey,
                        sigData.validUntil,
                        sigData.resolver,
                        sigData.permit2SourceChainId,
                        sigData.permit2Contract,
                        sigData.permit2Arbiter,
                        sigData.permit2Nonce,
                        sigData.permit2Expires
                    );
                if (_recover(permit2Digest, sigData.ownerSignature) != sigData.owner) {
                    revert InvalidSigner();
                }
            }
            if (_recover(hash, sigData.sessionSignature) != sigData.sessionKey) {
                revert InvalidSigner();
            }
        }

        _checkRegistrationPolicy(sigData.owner, sigData.resolver, sigData.operationData);
        return ERC1271_MAGICVALUE;
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

    /// @notice Returns whether this stateless module is initialized for an account.
    /// @param account Unused account address.
    /// @return Always true because there is no per-account storage.
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

    /// @notice Computes the legacy owner-signed registration session grant hash.
    /// @dev Uses the destination chain id so grants cannot be replayed across chains.
    function _registrationSessionGrantHash(
        address hca,
        address owner,
        address sessionKey,
        uint48 validUntil,
        address resolver
    )
        internal
        view
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    SESSION_GRANT_TYPEHASH,
                    block.chainid,
                    hca,
                    owner,
                    sessionKey,
                    validUntil,
                    resolver
                )
            );
    }

    /// @notice Computes the Permit2-shaped owner authorization digest for a session grant.
    /// @dev Mirrors the Rhinestone JIT Permit2 hashing shape; nonce consumption happens upstream.
    function _permit2SessionDigest(
        address hca,
        address owner,
        address sessionKey,
        uint48 validUntil,
        address resolver,
        uint256 sourceChainId,
        address permit2Contract,
        address arbiter,
        uint256 nonce,
        uint256 expires
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 grantHash =
            keccak256(
                abi.encode(
                    PERMIT2_SESSION_GRANT_TYPEHASH,
                    block.chainid,
                    hca,
                    owner,
                    sessionKey,
                    validUntil,
                    resolver
                )
            );
        bytes32 mandate =
            keccak256(
                abi.encode(
                    PERMIT2_MANDATE_TYPEHASH,
                    bytes32(0),
                    uint128(0),
                    grantHash,
                    NO_OPS_HASH,
                    bytes32(0)
                )
            );
        bytes32 permit2Hash =
            keccak256(
                abi.encode(PERMIT2_JIT_TYPEHASH, EMPTY_ARRAY_HASH, arbiter, nonce, expires, mandate)
            );
        bytes32 domainSeparator =
            keccak256(
                abi.encode(
                    PERMIT2_DOMAIN_TYPEHASH,
                    PERMIT2_NAME_HASH,
                    sourceChainId,
                    permit2Contract
                )
            );

        return keccak256(abi.encodePacked(bytes2(0x1901), domainSeparator, permit2Hash));
    }

    /// @notice Validates every execution against the hardcoded registration action set.
    /// @dev Checks target, selector, value, and selected ABI arguments for each execution.
    /// @param owner The owner recorded for the HCA.
    /// @param allowedResolver The resolver authorized by the owner grant.
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
            operationData.length < 2 ||
            operationData[0] != bytes1(uint8(2)) ||
            operationData[1] != bytes1(uint8(1))
        ) {
            revert InvalidOperationEncoding();
        }

        Execution[] memory executions = abi.decode(operationData[2:], (Execution[]));
        address registeredResolver;

        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            if (
                execution.target == ETH_REGISTRAR &&
                _selector(execution.callData) == REGISTER_SELECTOR
            ) {
                if (_readAddress(execution.callData, 4 + 32) != owner) {
                    revert PolicyRuleFailed();
                }
                address resolver = _readAddress(execution.callData, 4 + 128);
                if (registeredResolver == address(0)) {
                    registeredResolver = resolver;
                } else if (registeredResolver != resolver) {
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
                if (selector == COMMIT_SELECTOR || selector == RENEW_SELECTOR) {
                    continue;
                }
                if (selector == REGISTER_SELECTOR) {
                    if (_readAddress(execution.callData, 4 + 32) != owner) {
                        revert PolicyRuleFailed();
                    }
                    if (_readAddress(execution.callData, 4 + 128) != policyResolver) {
                        revert PolicyRuleFailed();
                    }
                    continue;
                }
                revert ActionNotAllowed(execution.target, selector);
            }

            if (policyResolver != address(0) && execution.target == policyResolver) {
                _checkResolverCall(execution.callData);
                continue;
            }

            if (execution.target == REVERSE_REGISTRAR_HCA_ADAPTER) {
                if (selector != CLAIM_WITH_HCA_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                if (policyResolver == address(0)) {
                    revert PolicyRuleFailed();
                }
                if (_readAddress(execution.callData, 4) != owner) {
                    revert PolicyRuleFailed();
                }
                if (_readAddress(execution.callData, 4 + 32) != policyResolver) {
                    revert PolicyRuleFailed();
                }
                continue;
            }

            if (execution.target == MOCK_USDC || execution.target == MOCK_DAI) {
                if (selector != APPROVE_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                if (_readAddress(execution.callData, 4) != ETH_REGISTRAR) {
                    revert PolicyRuleFailed();
                }
                continue;
            }

            if (execution.target == VERIFIABLE_FACTORY) {
                if (selector != DEPLOY_PROXY_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                if (_readAddress(execution.callData, 4) != PERMITTED_RESOLVER_IMPL) {
                    revert PolicyRuleFailed();
                }
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
    /// @dev Allows known resolver setters directly or recursively through supported multicalls.
    /// @param callData ABI-encoded resolver call data.
    function _checkResolverCall(bytes memory callData) internal pure {
        bytes4 selector = _selector(callData);
        if (selector == MULTICALL_SELECTOR) {
            bytes[] memory calls = abi.decode(_callArgs(callData), (bytes[]));
            _checkResolverCalls(calls);
            return;
        }
        if (selector == MULTICALL_WITH_NODE_CHECK_SELECTOR) {
            (, bytes[] memory calls) = abi.decode(_callArgs(callData), (bytes32, bytes[]));
            _checkResolverCalls(calls);
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
    function _checkResolverCalls(bytes[] memory calls) internal pure {
        for (uint256 i; i < calls.length; ++i) {
            _checkResolverCall(calls[i]);
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

    /// @notice Recovers the signer of a 65-byte ECDSA signature.
    /// @dev Accepts signatures with v encoded as 0/1 or 27/28.
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
        if (v < 27) {
            v += 27;
        }
        signer = ecrecover(digest, v, r, s);
        if (signer == address(0)) {
            revert InvalidSigner();
        }
    }

    /// @notice Applies the standard EIP-191 message prefix to a digest.
    /// @dev Matches `personal_sign` / `signMessage` for a 32-byte digest.
    /// @param digest The raw digest.
    /// @return The Ethereum signed message hash.
    function _toEthSignedMessageHash(bytes32 digest) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", digest));
    }
}
