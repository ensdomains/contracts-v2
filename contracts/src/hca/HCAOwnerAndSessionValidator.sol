// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {CloneProxyBytecode} from "@ensdomains/verifiable-factory/CloneProxyBytecode.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Create2} from "@openzeppelin/contracts/utils/Create2.sol";
import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IValidator} from "nexus/interfaces/modules/IValidator.sol";

import {EACBaseRolesLib} from "../access-control/libraries/EACBaseRolesLib.sol";
import {IETHRegistrar} from "../registrar/interfaces/IETHRegistrar.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";
import {
    IDefaultReverseRegistrarAdapter
} from "../reverse-registrar/interfaces/IDefaultReverseRegistrarAdapter.sol";
import {
    IReverseRegistrarAdapter
} from "../reverse-registrar/interfaces/IReverseRegistrarAdapter.sol";

import {IStandaloneHCAOwner} from "./interfaces/IStandaloneHCAOwner.sol";

/// @notice Resolver calls encoded and validated by the HCA registration policy.
/// @dev Interface selector: `0xcb811eec`
interface IHCARegistrationResolver {
    /// @notice Initializes a resolver proxy for an account.
    /// @param admin The initial resolver administrator.
    /// @param roleBitmap The roles granted to the administrator.
    /// @param setters Initial resolver calls executed during initialization.
    function initialize(address admin, uint256 roleBitmap, bytes[] calldata setters) external;

    /// @notice Updates an account's roles for an ENS name.
    /// @param name The DNS-encoded name whose roles are updated.
    /// @param roleBitmap The roles to update.
    /// @param account The account receiving or losing the roles.
    /// @param grant Whether the roles are granted or revoked.
    /// @return success Whether the roles were updated.
    function authorizeNameRoles(bytes calldata name, uint256 roleBitmap, address account, bool grant)
        external
        returns (bool success);
}


/// @title HCA Owner and Session Validator
/// @notice Fixed validator for standalone HCA owner authorization and scoped ENS sessions.
/// @dev Owner signatures use Rhinestone's existing HCA format. Sessions are enabled by an
///      owner-authorized HCA call and consumed through the IntentExecutor's ERC-1271 path. The
///      permission checks remain hardcoded here rather than in dynamic policy modules.
contract HCAOwnerAndSessionValidator is IValidator {
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

    /// @notice Executor reimbursement included in a single-chain intent.
    struct GasRefund {
        address token;
        uint256 exchangeRate;
        uint256 overhead;
    }

    /// @dev Permit2 fields carried by the cross-chain fixed-session envelope.
    struct Permit2Fields {
        address spender;
        uint256 nonce;
        uint256 deadline;
        address sourceToken;
        uint256 sourceAmount;
        address recipient;
        uint256 targetChainId;
        uint256 fillExpiry;
        address tokenOut;
        uint256 amountOut;
    }

    /// @notice Compact configuration for one pre-enabled registration session.
    struct SessionConfig {
        address sessionKey;
        uint48 validUntil;
        uint48 maxRefundGasOverhead;
        address resolver;
        uint96 sessionNonce;
        address refundToken;
        uint96 maxRefundExchangeRate;
        uint96 maxRefundAmount;
    }

    /// @dev One chain and session digest from a Rhinestone multi-chain session authorization.
    struct HashAndChainId {
        uint64 chainId;
        bytes32 sessionDigest;
    }

    /// @dev Owner authorization used when the first route enables an HCA session.
    struct SessionEnableProof {
        address sessionKey;
        uint48 validUntil;
        uint96 sessionNonce;
        address resolver;
        address refundToken;
        uint96 maxRefundExchangeRate;
        uint48 maxRefundGasOverhead;
        uint96 maxRefundAmount;
        uint8 sessionToEnableIndex;
        HashAndChainId[] hashesAndChainIds;
        bytes32 ownerR;
        bytes32 ownerS;
        uint8 ownerV;
    }

    /// @dev State collected while the validator checks one operation batch.
    struct RegistrationPolicyState {
        bool usesResolver;
        bool deploysResolver;
        bool grantsOwnerResolverRoles;
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

    /// @dev ERC-4337 validation success value.
    uint256 internal constant VALIDATION_SUCCESS = 0;

    /// @dev ERC-4337 validation failure value.
    uint256 internal constant VALIDATION_FAILED = 1;

    /// @dev Length of one ECDSA signature.
    uint256 internal constant ECDSA_SIGNATURE_LENGTH = 65;

    /// @dev Fixed-session discriminator inside the validator signature.
    bytes1 internal constant FIXED_SESSION_MODE = 0x01;

    /// @dev Refund-aware fixed-session discriminator inside the validator signature.
    bytes1 internal constant FIXED_SESSION_REFUND_MODE = 0x02;

    /// @dev Fixed-session discriminator for a Permit2-backed cross-chain intent.
    bytes1 internal constant FIXED_SESSION_PERMIT2_MODE = 0x03;

    /// @dev First-use Permit2 mode carrying one reusable multi-chain session authorization.
    bytes1 internal constant FIXED_SESSION_PERMIT2_ENABLE_MODE = 0x04;

    /// @dev First-use single-chain mode carrying one reusable multi-chain session authorization.
    bytes1 internal constant FIXED_SESSION_REFUND_ENABLE_MODE = 0x05;

    /// @dev Size of the fixed-session mode, permission ID, and standalone-intent nonce.
    uint256 internal constant FIXED_SESSION_PREFIX_LENGTH = 65;

    /// @dev Size of the fixed-session prefix when it also carries a gas-refund tuple.
    uint256 internal constant FIXED_SESSION_REFUND_PREFIX_LENGTH = 149;

    /// @dev Fields after a first-use proof and before its single-chain operation.
    uint256 internal constant FIXED_SESSION_REFUND_ENABLE_FIELDS_LENGTH = 116;

    /// @dev Fixed Permit2 claim fields produced by the Rhinestone SDK.
    uint256 internal constant PERMIT2_CLAIM_DATA_LENGTH = 410;

    /// @dev Mode, permission ID, origin chain ID, and fixed Permit2 claim fields.
    uint256 internal constant FIXED_SESSION_PERMIT2_OPERATION_OFFSET =
        65 + PERMIT2_CLAIM_DATA_LENGTH;

    /// @dev Mode, permission ID, and four-byte enable-proof length.
    uint256 internal constant FIXED_SESSION_ENABLE_PREFIX_LENGTH = 37;

    /// @dev Minimum envelope size before the first same-chain operation.
    uint256 internal constant FIXED_SESSION_REFUND_ENABLE_MIN_LENGTH =
        FIXED_SESSION_ENABLE_PREFIX_LENGTH +
        FIXED_SESSION_REFUND_ENABLE_FIELDS_LENGTH + ECDSA_SIGNATURE_LENGTH;

    /// @dev Smart Session payload mode for an already-enabled permission.
    bytes1 internal constant SMART_SESSION_MODE_USE = 0x00;

    /// @dev Existing Smart Session USE payload size for one ECDSA session signer.
    uint256 internal constant SMART_SESSION_USE_LENGTH = 98;

    /// @notice Rhinestone operation mode for pure emissary ERC-7579 execution.
    bytes32 public constant ERC7579_EMISSARY_EXECUTION_MODE = bytes32(uint256(0x0204) << 240);

    /// @notice Rhinestone operation mode for ERC-1271 ERC-7579 execution.
    bytes32 public constant ERC7579_ERC1271_MODE = bytes32(uint256(0x0201) << 240);

    /// @notice Rhinestone operation mode for ERC-1271 with emissary-execution fallback.
    bytes32 public constant ERC7579_ERC1271_EMISSARY_EXECUTION_MODE =
        bytes32(uint256(0x0206) << 240);

    /// @dev EIP-712 domain type used by the production IntentExecutor.
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );

    /// @dev EIP-712 domain name used by the production IntentExecutor.
    bytes32 internal constant INTENT_EXECUTOR_NAME_HASH = keccak256("IntentExecutor");

    /// @dev EIP-712 domain version used by the production IntentExecutor.
    bytes32 internal constant INTENT_EXECUTOR_VERSION_HASH = keccak256("v0.0.1");

    /// @dev EIP-712 type hash for one standalone single-chain intent.
    bytes32 internal constant SINGLE_CHAIN_OPS_TYPEHASH =
        0xbae11135c33effc421d699bbb53d9926a005ed0f2f5eb672c62cbfa943807291;

    /// @dev EIP-712 type hash for the operation wrapper.
    bytes32 internal constant OP_TYPEHASH =
        0xdbc520cb50a8aaf3fa06ea43dc3d59d248e52ae638476e3268a1e6e36bffe196;

    /// @dev EIP-712 type hash for one ERC-7579 execution.
    bytes32 internal constant EXECUTION_TYPEHASH =
        0x09b0a32e9842b65559835c235891737e06927d59e48a6f0e0512e136a513a9e4;

    /// @dev EIP-712 type hash for executor reimbursement.
    bytes32 internal constant GAS_REFUND_TYPEHASH =
        0x0bf04d9dcc5e703a75ba16d19c00f9d87fa30b9a815627102c15624d338eb094;

    /// @dev IntentExecutor hash for an intent without a gas refund.
    bytes32 internal constant NO_GAS_REFUND_HASH =
        0x44db4de84d423abe696e354fc99de162153ee2f8985ab84305061247a78a3be4;

    /// @dev Canonical Permit2 deployment used by Rhinestone intents.
    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

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

    /// @dev Permit2 EIP-712 domain type hash.
    bytes32 internal constant PERMIT2_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,uint256 chainId,address verifyingContract)");

    /// @dev Permit2 EIP-712 name hash.
    bytes32 internal constant PERMIT2_NAME_HASH = keccak256("Permit2");

    /// @dev Permit2 token-permissions type hash.
    bytes32 internal constant TOKEN_PERMISSIONS_TYPEHASH =
        keccak256("TokenPermissions(address token,uint256 amount)");

    /// @dev Permit2 destination-token type hash.
    bytes32 internal constant TOKEN_TYPEHASH = keccak256("Token(address token,uint256 amount)");

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

    /// @notice Selector for ETHRegistrar.commit(bytes32).
    bytes4 public constant COMMIT_SELECTOR = IETHRegistrar.commit.selector;

    /// @notice Selector for ETHRegistrar.register(string,address,bytes32,address,address,uint64,address,bytes32).
    bytes4 public constant REGISTER_SELECTOR = IETHRegistrar.register.selector;

    /// @notice Selector for ERC20.approve(address,uint256).
    bytes4 public constant APPROVE_SELECTOR = IERC20.approve.selector;

    /// @notice Selector for EIP-2612 permit(address,address,uint256,uint256,uint8,bytes32,bytes32).
    bytes4 public constant PERMIT_SELECTOR = 0xd505accf;

    /// @notice Selector for ERC20.transferFrom(address,address,uint256).
    bytes4 public constant TRANSFER_FROM_SELECTOR = IERC20.transferFrom.selector;

    /// @notice Selector for VerifiableFactory.deployProxy(address,uint256,bytes).
    bytes4 public constant DEPLOY_PROXY_SELECTOR = IVerifiableFactory.deployProxy.selector;

    /// @notice Selector for DefaultReverseRegistrarAdapter.setNameWithHCA(address,string).
    bytes4 public constant SET_NAME_WITH_HCA_SELECTOR =
        IDefaultReverseRegistrarAdapter.setNameWithHCA.selector;

    /// @notice Selector for ReverseRegistrarAdapter.claimWithHCA(address,address).
    bytes4 public constant CLAIM_WITH_HCA_SELECTOR = IReverseRegistrarAdapter.claimWithHCA.selector;

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
        IHCARegistrationResolver.authorizeNameRoles.selector;

    /// @notice The HCA-aware default reverse registrar adapter permitted for default primary-name setup.
    address public immutable DEFAULT_REVERSE_REGISTRAR_HCA_ADAPTER;

    /// @notice The HCA-aware `addr.reverse` registrar adapter permitted for v1 reverse claims.
    address public immutable REVERSE_REGISTRAR_HCA_ADAPTER;

    /// @notice The resolver implementation permitted for resolver deployment.
    address public immutable PERMITTED_RESOLVER_IMPL;

    /// @notice The ENS registry whose root registrar role authorizes registration targets.
    address public immutable ETH_REGISTRY;

    /// @notice The VerifiableFactory permitted for resolver deployment.
    address public immutable VERIFIABLE_FACTORY;

    /// @notice The proxy logic used by the permitted VerifiableFactory.
    address public immutable VERIFIABLE_PROXY_LOGIC;

    /// @notice The primary ERC20 payment token accepted by the registration policy.
    address public immutable PAYMENT_TOKEN;

    /// @notice The secondary ERC20 payment token accepted by the registration policy.
    address public immutable SECONDARY_PAYMENT_TOKEN;

    /// @notice The only executor allowed to present session operations for verification.
    address public immutable INTENT_EXECUTOR;

    /// @notice The Rhinestone paymaster permitted to pull a signed executor refund.
    address public immutable GAS_REFUND_PAYMASTER;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Fixed session configuration by account and permission ID.
    mapping(address account => mapping(bytes32 permissionId => SessionConfig config)) internal _sessions;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when an account enables a fixed session.
    /// @param account The HCA that enabled the session.
    /// @param permissionId The session permission identifier.
    /// @param sessionKey The authorized session signer.
    /// @param resolver The resolver allowed by the session policy.
    /// @param validUntil The last timestamp at which the session is valid.
    /// @param sessionNonce The account nonce that invalidates older sessions.
    event SessionEnabled(
        address indexed account,
        bytes32 indexed permissionId,
        address indexed sessionKey,
        address resolver,
        uint48 validUntil,
        uint96 sessionNonce
    );

    /// @notice Emitted when a fixed session permits executor reimbursement.
    /// @param account The HCA that enabled the session.
    /// @param permissionId The session permission identifier.
    /// @param token The permitted reimbursement token.
    /// @param maxExchangeRate The maximum signed token exchange rate.
    /// @param maxGasOverhead The maximum signed gas overhead.
    /// @param maxRefundAmount The maximum token reimbursement.
    event SessionRefundConfigured(
        address indexed account,
        bytes32 indexed permissionId,
        address indexed token,
        uint96 maxExchangeRate,
        uint48 maxGasOverhead,
        uint96 maxRefundAmount
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
    /// @dev Error selector: `0x037b5679`
    error CallerNotIntentExecutor();

    /// @notice A session payload is not the supported Smart Session USE form.
    /// @dev Error selector: `0x9bdfc59f`
    error InvalidSessionData();

    /// @notice A target/action pair is outside the hardcoded registration policy.
    /// @param target The forbidden execution target.
    /// @param selector The forbidden function selector.
    /// @dev Error selector: `0xde1834f2`
    error ActionNotAllowed(address target, bytes4 selector);

    /// @notice One of the hardcoded policy argument checks failed.
    /// @dev Error selector: `0xe50c42ea`
    error PolicyRuleFailed();

    /// @notice A fixed session did not authorize the supplied executor reimbursement.
    /// @dev Error selector: `0x0672e151`
    error GasRefundNotAllowed();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param defaultReverseRegistrarHcaAdapter The HCA-aware default reverse registrar adapter.
    /// @param reverseRegistrarHcaAdapter The HCA-aware `addr.reverse` registrar adapter.
    /// @param permittedResolverImpl The resolver implementation accepted in resolver deployment actions.
    /// @param ethRegistry The ENS registry that authorizes registrars through its root roles.
    /// @param verifiableFactory The VerifiableFactory accepted by the registration policy.
    /// @param paymentToken The primary ERC20 payment token accepted by the registration policy.
    /// @param secondaryPaymentToken The secondary ERC20 payment token accepted by the registration policy.
    /// @param intentExecutor The fixed IntentExecutor allowed to present sponsored operations.
    /// @param gasRefundPaymaster The paymaster allowed to settle signed executor refunds.
    constructor(
        address defaultReverseRegistrarHcaAdapter,
        address reverseRegistrarHcaAdapter,
        address permittedResolverImpl,
        address ethRegistry,
        address verifiableFactory,
        address paymentToken,
        address secondaryPaymentToken,
        address intentExecutor,
        address gasRefundPaymaster
    )
    {
        DEFAULT_REVERSE_REGISTRAR_HCA_ADAPTER = defaultReverseRegistrarHcaAdapter;
        REVERSE_REGISTRAR_HCA_ADAPTER = reverseRegistrarHcaAdapter;
        PERMITTED_RESOLVER_IMPL = permittedResolverImpl;
        ETH_REGISTRY = ethRegistry;
        VERIFIABLE_FACTORY = verifiableFactory;
        VERIFIABLE_PROXY_LOGIC = VerifiableFactory(verifiableFactory).proxyLogic();
        PAYMENT_TOKEN = paymentToken;
        SECONDARY_PAYMENT_TOKEN = secondaryPaymentToken;
        INTENT_EXECUTOR = intentExecutor;
        GAS_REFUND_PAYMASTER = gasRefundPaymaster;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Enables one fixed-policy session through an owner-authorized HCA execution.
    /// @dev `msg.sender` is the HCA, so the enable call can be batched with its first owner-signed
    ///      intent. `permissionId` is the ID used by Rhinestone's existing session USE payload.
    /// @param permissionId The session permission identifier.
    /// @param sessionKey The ECDSA key authorized for the fixed ENS policy.
    /// @param validUntil The last timestamp at which the session is valid.
    /// @param resolver The resolver accepted by the fixed ENS policy.
    function enableSession(
        bytes32 permissionId,
        address sessionKey,
        uint48 validUntil,
        address resolver
    )
        external
    {
        _enableSession(permissionId, sessionKey, validUntil, resolver, address(0), 0, 0, 0);
    }

    /// @notice Enables one fixed-policy session that may reimburse the executor in a payment token.
    /// @param permissionId The ID used by Rhinestone's existing session USE payload.
    /// @param sessionKey The ECDSA key authorized for the fixed ENS policy.
    /// @param validUntil The last timestamp at which the session is valid.
    /// @param resolver The resolver accepted by the fixed ENS policy.
    /// @param refundToken The payment token accepted for executor reimbursement.
    /// @param maxRefundExchangeRate The largest token exchange rate the session may sign.
    /// @param maxRefundGasOverhead The largest gas-unit overhead the session may sign.
    /// @param maxRefundAmount The largest token-denominated refund cap the session may sign.
    function enableSessionWithRefund(
        bytes32 permissionId,
        address sessionKey,
        uint48 validUntil,
        address resolver,
        address refundToken,
        uint96 maxRefundExchangeRate,
        uint48 maxRefundGasOverhead,
        uint96 maxRefundAmount
    )
        external
    {
        if (
            (refundToken != PAYMENT_TOKEN && refundToken != SECONDARY_PAYMENT_TOKEN) ||
            maxRefundExchangeRate == 0 ||
            maxRefundAmount == 0
        ) {
            revert GasRefundNotAllowed();
        }
        _enableSession(
            permissionId,
            sessionKey,
            validUntil,
            resolver,
            refundToken,
            maxRefundExchangeRate,
            maxRefundGasOverhead,
            maxRefundAmount
        );
        emit SessionRefundConfigured(
            msg.sender,
            permissionId,
            refundToken,
            maxRefundExchangeRate,
            maxRefundGasOverhead,
            maxRefundAmount
        );
    }

    /// @notice Validates an HCA owner signature or a pre-enabled fixed session.
    /// @param sender The caller forwarded by the account.
    /// @param hash The digest supplied by the intent executor.
    /// @param data A 65-byte owner signature or fixed-session envelope.
    /// @return magicValue ERC-1271 success value.
    function isValidSignatureWithSender(address sender, bytes32 hash, bytes calldata data)
        external
        view
        returns (bytes4 magicValue)
    {
        if (sender != INTENT_EXECUTOR) {
            revert CallerNotIntentExecutor();
        }
        if (data.length == ECDSA_SIGNATURE_LENGTH) {
            (address expectedOwner, ) = _ownerAndSessionNonce(msg.sender);
            if (_recover(hash, data) != expectedOwner) {
                revert InvalidSigner();
            }
        } else {
            _validateFixedSession(hash, data);
        }
        return ERC1271_MAGICVALUE;
    }

    /// @notice Returns whether a fixed-policy session is currently usable.
    /// @param account The HCA that owns the session.
    /// @param permissionId The session permission identifier.
    /// @return Whether the session exists, has not expired, and matches the account nonce.
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
    /// @param account The HCA that owns the session.
    /// @param digest The operation digest signed by the session key.
    /// @param data The Smart Session USE payload.
    /// @param operation The operation supplied by the fixed executor.
    /// @return The verification function selector on success.
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

        _checkRegistrationPolicy(account, owner_, config.resolver, operation.data);
        return this.verifyExecution.selector;
    }

    /// @notice Validates an owner-signed ERC-4337 UserOperation.
    /// @dev Accepts both raw-digest and `personal_sign` ECDSA signatures, matching Nexus's K1 validator.
    ///      Fixed sessions remain limited to the intent path.
    /// @param userOp The UserOperation forwarded by the HCA.
    /// @param userOpHash The EntryPoint digest signed by the owner.
    /// @return The ERC-4337 validation result.
    function validateUserOp(PackedUserOperation calldata userOp, bytes32 userOpHash)
        external
        view
        returns (uint256)
    {
        if (userOp.sender != msg.sender) {
            return VALIDATION_FAILED;
        }
        (address expectedOwner, ) = _ownerAndSessionNonce(msg.sender);
        return
            _isValidUserOpSignature(expectedOwner, userOpHash, userOp.signature)
                ? VALIDATION_SUCCESS
                : VALIDATION_FAILED;
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

    /// @dev Stores a fixed session and binds it to the account's current session nonce.
    function _enableSession(
        bytes32 permissionId,
        address sessionKey,
        uint48 validUntil,
        address resolver,
        address refundToken,
        uint96 maxRefundExchangeRate,
        uint48 maxRefundGasOverhead,
        uint96 maxRefundAmount
    )
        internal
    {
        _enableSessionFor(
            msg.sender,
            permissionId,
            sessionKey,
            validUntil,
            resolver,
            refundToken,
            maxRefundExchangeRate,
            maxRefundGasOverhead,
            maxRefundAmount
        );
    }

    /// @dev Stores a fixed session for an HCA after checking its current session nonce.
    function _enableSessionFor(
        address account,
        bytes32 permissionId,
        address sessionKey,
        uint48 validUntil,
        address resolver,
        address refundToken,
        uint96 maxRefundExchangeRate,
        uint48 maxRefundGasOverhead,
        uint96 maxRefundAmount
    )
        internal
    {
        if (sessionKey == address(0)) {
            revert InvalidSigner();
        }
        if (validUntil < block.timestamp) {
            revert SessionExpired();
        }
        (, uint96 sessionNonce) = _ownerAndSessionNonce(account);
        _sessions[account][permissionId] = SessionConfig({sessionKey: sessionKey, validUntil: validUntil, maxRefundGasOverhead: maxRefundGasOverhead, resolver: resolver, sessionNonce: sessionNonce, refundToken: refundToken, maxRefundExchangeRate: maxRefundExchangeRate, maxRefundAmount: maxRefundAmount});
        emit SessionEnabled(account, permissionId, sessionKey, resolver, validUntil, sessionNonce);
    }

    /// @dev Reads the account owner and session nonce, reverting if either is unavailable.
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

    /// @dev Validates an ERC-1271 session envelope and binds its operation copy to `hash`.
    function _validateFixedSession(bytes32 hash, bytes calldata data) internal view {
        if (data.length < FIXED_SESSION_PREFIX_LENGTH + ECDSA_SIGNATURE_LENGTH) {
            revert InvalidSessionData();
        }

        bytes1 mode = data[0];
        if (mode == FIXED_SESSION_PERMIT2_ENABLE_MODE) {
            _validateFixedPermit2SessionEnable(hash, data);
            return;
        }
        if (mode == FIXED_SESSION_REFUND_ENABLE_MODE) {
            _validateFixedRefundSessionEnable(hash, data);
            return;
        }
        if (mode == FIXED_SESSION_PERMIT2_MODE) {
            _validateFixedPermit2Session(hash, data);
            return;
        }
        if (mode == FIXED_SESSION_MODE) {
            _validateFixedSessionPayload(
                hash,
                data,
                FIXED_SESSION_PREFIX_LENGTH,
                GasRefund(address(0), 0, 0)
            );
            return;
        }
        if (mode == FIXED_SESSION_REFUND_MODE) {
            if (data.length < FIXED_SESSION_REFUND_PREFIX_LENGTH + ECDSA_SIGNATURE_LENGTH) {
                revert InvalidSessionData();
            }
            _validateFixedSessionPayload(
                hash,
                data,
                FIXED_SESSION_REFUND_PREFIX_LENGTH,
                GasRefund({token: address(bytes20(data[65:85])), exchangeRate: uint256(
                    bytes32(data[85:117])
                ), overhead: uint256(bytes32(data[117:149]))})
            );
            return;
        }
        revert InvalidSessionData();
    }

    /// @dev Validates the first Permit2 route and its reusable multi-chain session authorization.
    function _validateFixedPermit2SessionEnable(bytes32 hash, bytes calldata data) internal view {
        if (data.length <= FIXED_SESSION_ENABLE_PREFIX_LENGTH + 32 + PERMIT2_CLAIM_DATA_LENGTH + 65) {
            revert InvalidSessionData();
        }

        bytes32 permissionId = bytes32(data[1:33]);
        uint256 proofLength = uint32(bytes4(data[33:37]));
        uint256 proofEnd = FIXED_SESSION_ENABLE_PREFIX_LENGTH + proofLength;
        uint256 operationOffset = proofEnd + 32 + PERMIT2_CLAIM_DATA_LENGTH;
        uint256 signatureOffset = data.length - ECDSA_SIGNATURE_LENGTH;
        if (proofLength == 0 || operationOffset >= signatureOffset) {
            revert InvalidSessionData();
        }

        SessionEnableProof memory proof =
            abi.decode(data[FIXED_SESSION_ENABLE_PREFIX_LENGTH:proofEnd], (SessionEnableProof));
        address accountOwner = _validateSessionEnableProof(permissionId, proof);
        _validatePermit2EnableIntent(hash, data, proofEnd, permissionId, accountOwner, proof);
    }

    /// @dev Validates the fixed HCA fields authorized by the owner.
    function _validateSessionEnableProof(bytes32 permissionId, SessionEnableProof memory proof)
        internal
        view
        returns (address owner_)
    {
        uint96 sessionNonce;
        (owner_, sessionNonce) = _ownerAndSessionNonce(msg.sender);
        if (
            proof.sessionKey == address(0) ||
            proof.validUntil < block.timestamp ||
            proof.sessionNonce != sessionNonce ||
            (proof.refundToken != PAYMENT_TOKEN && proof.refundToken != SECONDARY_PAYMENT_TOKEN) ||
            proof.maxRefundExchangeRate == 0 ||
            proof.maxRefundAmount == 0
        ) {
            revert InvalidSessionData();
        }

        bytes32 salt = _sessionAuthorizationSalt(proof);
        bytes memory validatorInitData = _sessionValidatorInitData(proof.sessionKey);
        if (
            permissionId !=
            keccak256(abi.encode(OWNABLE_SESSION_VALIDATOR, validatorInitData, salt))
        ) {
            revert InvalidSessionData();
        }
        _validateMultiChainSessionAuthorization(owner_, salt, validatorInitData, proof);
        return owner_;
    }

    /// @dev Validates the session-signed Permit2 intent and its exact first HCA operation.
    function _validatePermit2EnableIntent(
        bytes32 hash,
        bytes calldata data,
        uint256 proofEnd,
        bytes32 permissionId,
        address accountOwner,
        SessionEnableProof memory proof
    )
        internal
        view
    {
        uint256 operationOffset = proofEnd + 32 + PERMIT2_CLAIM_DATA_LENGTH;
        uint256 signatureOffset = data.length - ECDSA_SIGNATURE_LENGTH;
        bytes calldata operationData = data[operationOffset:signatureOffset];
        if (_recover(hash, data[signatureOffset:]) != proof.sessionKey) {
            revert InvalidSigner();
        }
        _validatePermit2Destination(
            hash,
            uint256(bytes32(data[proofEnd:proofEnd + 32])),
            data[proofEnd + 32:operationOffset],
            operationData
        );
        _checkInitialRegistrationPolicy(
            msg.sender,
            accountOwner,
            permissionId,
            proof,
            operationData,
            GasRefund(address(0), 0, 0)
        );
    }

    /// @dev Validates the first same-chain operation and its reusable session authorization.
    function _validateFixedRefundSessionEnable(bytes32 hash, bytes calldata data) internal view {
        if (data.length <= FIXED_SESSION_REFUND_ENABLE_MIN_LENGTH) {
            revert InvalidSessionData();
        }

        bytes32 permissionId = bytes32(data[1:33]);
        uint256 proofLength = uint32(bytes4(data[33:37]));
        uint256 proofEnd = FIXED_SESSION_ENABLE_PREFIX_LENGTH + proofLength;
        if (
            proofLength == 0 ||
            proofEnd + FIXED_SESSION_REFUND_ENABLE_FIELDS_LENGTH >=
            data.length - ECDSA_SIGNATURE_LENGTH
        ) {
            revert InvalidSessionData();
        }

        SessionEnableProof memory proof =
            abi.decode(data[FIXED_SESSION_ENABLE_PREFIX_LENGTH:proofEnd], (SessionEnableProof));
        address accountOwner = _validateSessionEnableProof(permissionId, proof);
        (bytes calldata operationData, GasRefund memory gasRefund) =
            _validateFixedRefundSessionEnablePayload(hash, data, proofEnd, proof);
        _checkInitialRegistrationPolicy(
            msg.sender,
            accountOwner,
            permissionId,
            proof,
            operationData,
            gasRefund
        );
    }

    /// @dev Validates the session signature, refund, and operation in a first same-chain use.
    function _validateFixedRefundSessionEnablePayload(
        bytes32 hash,
        bytes calldata data,
        uint256 proofEnd,
        SessionEnableProof memory proof
    )
        internal
        view
        returns (bytes calldata operationData, GasRefund memory gasRefund)
    {
        uint256 operationOffset = proofEnd + FIXED_SESSION_REFUND_ENABLE_FIELDS_LENGTH;
        uint256 signatureOffset = data.length - ECDSA_SIGNATURE_LENGTH;
        gasRefund = GasRefund({token: address(bytes20(data[proofEnd + 32:proofEnd + 52])), exchangeRate: uint256(
            bytes32(data[proofEnd + 52:proofEnd + 84])
        ), overhead: uint256(bytes32(data[proofEnd + 84:operationOffset]))});
        SessionConfig memory config =
            SessionConfig({sessionKey: proof.sessionKey, validUntil: proof.validUntil, maxRefundGasOverhead: proof.maxRefundGasOverhead, resolver: proof.resolver, sessionNonce: proof.sessionNonce, refundToken: proof.refundToken, maxRefundExchangeRate: proof.maxRefundExchangeRate, maxRefundAmount: proof.maxRefundAmount});
        _checkGasRefund(config, gasRefund);

        operationData = data[operationOffset:signatureOffset];
        uint256 nonce = uint256(bytes32(data[proofEnd:proofEnd + 32]));
        if (_singleChainDigest(msg.sender, nonce, operationData, gasRefund) != hash) {
            revert InvalidSessionData();
        }
        if (_recover(hash, data[signatureOffset:]) != proof.sessionKey) {
            revert InvalidSigner();
        }
    }

    /// @dev Validates the standard Rhinestone multi-chain session signature once for this HCA.
    function _validateMultiChainSessionAuthorization(
        address owner_,
        bytes32 salt,
        bytes memory validatorInitData,
        SessionEnableProof memory proof
    )
        internal
        view
    {
        uint256 count = proof.hashesAndChainIds.length;
        uint256 selectedIndex = proof.sessionToEnableIndex;
        if (count == 0 || selectedIndex >= count) {
            revert InvalidSessionData();
        }

        bytes32 signedSessionHash =
            keccak256(
                abi.encode(
                    SIGNED_SESSION_TYPEHASH,
                    msg.sender,
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
            revert InvalidSessionData();
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
        if (_recoverParts(digest, proof.ownerR, proof.ownerS, proof.ownerV) != owner_) {
            revert InvalidSigner();
        }
    }

    /// @dev Validates a cross-chain Permit2 intent and its destination operation preimage.
    function _validateFixedPermit2Session(bytes32 hash, bytes calldata data) internal view {
        if (data.length <= FIXED_SESSION_PERMIT2_OPERATION_OFFSET + ECDSA_SIGNATURE_LENGTH) {
            revert InvalidSessionData();
        }

        bytes32 permissionId = bytes32(data[1:33]);
        SessionConfig memory config = _sessions[msg.sender][permissionId];
        if (config.sessionKey == address(0)) {
            revert InvalidSigner();
        }
        if (block.timestamp > config.validUntil) {
            revert SessionExpired();
        }
        (, uint96 sessionNonce) = _ownerAndSessionNonce(msg.sender);
        if (sessionNonce != config.sessionNonce) {
            revert InvalidSigner();
        }

        uint256 sourceChainId = uint256(bytes32(data[33:65]));
        bytes calldata claimData = data[65:FIXED_SESSION_PERMIT2_OPERATION_OFFSET];
        uint256 signatureOffset = data.length - ECDSA_SIGNATURE_LENGTH;
        bytes calldata operationData = data[FIXED_SESSION_PERMIT2_OPERATION_OFFSET:signatureOffset];
        if (_recover(hash, data[signatureOffset:]) != config.sessionKey) {
            revert InvalidSigner();
        }
        _validatePermit2Destination(hash, sourceChainId, claimData, operationData);

        (address owner_, ) = _ownerAndSessionNonce(msg.sender);
        _checkRegistrationPolicy(
            msg.sender,
            owner_,
            config.resolver,
            operationData,
            GasRefund(address(0), 0, 0)
        );
    }

    /// @dev Binds the destination operation to the signed Permit2 mandate.
    function _validatePermit2Destination(
        bytes32 expectedDigest,
        uint256 sourceChainId,
        bytes calldata claimData,
        bytes calldata operationData
    )
        internal
        view
    {
        if (
            sourceChainId == 0 ||
            claimData.length != PERMIT2_CLAIM_DATA_LENGTH ||
            address(bytes20(claimData[0:20])) == address(0) ||
            uint8(claimData[84]) != 1 ||
            uint8(claimData[233]) != 1
        ) {
            revert PolicyRuleFailed();
        }

        Permit2Fields memory claim = _decodePermit2Fields(claimData);
        if (
            claim.deadline < block.timestamp ||
            claim.recipient != msg.sender ||
            claim.targetChainId != block.chainid ||
            claim.fillExpiry < block.timestamp ||
            (claim.tokenOut != PAYMENT_TOKEN && claim.tokenOut != SECONDARY_PAYMENT_TOKEN) ||
            claim.amountOut == 0
        ) {
            revert PolicyRuleFailed();
        }
        if (
            _operationHash(operationData) != bytes32(claimData[346:378]) ||
            _permit2Digest(claimData, sourceChainId) != expectedDigest
        ) {
            revert InvalidSessionData();
        }
    }

    /// @dev Validates the common fixed-session fields after decoding its refund mode.
    function _validateFixedSessionPayload(
        bytes32 hash,
        bytes calldata data,
        uint256 operationOffset,
        GasRefund memory gasRefund
    )
        internal
        view
    {
        bytes32 permissionId = bytes32(data[1:33]);
        SessionConfig memory config = _sessions[msg.sender][permissionId];
        if (config.sessionKey == address(0)) {
            revert InvalidSigner();
        }
        if (block.timestamp > config.validUntil) {
            revert SessionExpired();
        }

        (address owner_, uint96 sessionNonce) = _ownerAndSessionNonce(msg.sender);
        if (sessionNonce != config.sessionNonce) {
            revert InvalidSigner();
        }
        _checkGasRefund(config, gasRefund);
        bytes calldata operationData =
            _validateFixedSessionSignature(hash, data, operationOffset, gasRefund, config.sessionKey);
        _checkRegistrationPolicy(msg.sender, owner_, config.resolver, operationData, gasRefund);
    }

    /// @dev Binds the operation and refund preimages to the session signature.
    function _validateFixedSessionSignature(
        bytes32 hash,
        bytes calldata data,
        uint256 operationOffset,
        GasRefund memory gasRefund,
        address sessionKey
    )
        internal
        view
        returns (bytes calldata operationData)
    {
        uint256 signatureOffset = data.length - ECDSA_SIGNATURE_LENGTH;
        operationData = data[operationOffset:signatureOffset];
        uint256 nonce = uint256(bytes32(data[33:65]));
        if (_singleChainDigest(msg.sender, nonce, operationData, gasRefund) != hash) {
            revert InvalidSessionData();
        }
        if (_recover(hash, data[signatureOffset:]) != sessionKey) {
            revert InvalidSigner();
        }
    }

    /// @dev Reconstructs the production IntentExecutor digest for a single-chain intent.
    function _singleChainDigest(
        address account,
        uint256 nonce,
        bytes calldata operationData,
        GasRefund memory gasRefund
    )
        internal
        view
        returns (bytes32)
    {
        bytes32 gasRefundHash = gasRefund.token == address(0) &&
        gasRefund.exchangeRate == 0 &&
        gasRefund.overhead == 0
        ? NO_GAS_REFUND_HASH
        : keccak256(
            abi.encode(
                GAS_REFUND_TYPEHASH,
                gasRefund.token,
                gasRefund.exchangeRate,
                gasRefund.overhead
            )
        );
        bytes32 structHash =
            keccak256(
                abi.encode(
                    SINGLE_CHAIN_OPS_TYPEHASH,
                    account,
                    nonce,
                    _operationHash(operationData),
                    gasRefundHash
                )
            );
        bytes32 domainSeparator =
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    INTENT_EXECUTOR_NAME_HASH,
                    INTENT_EXECUTOR_VERSION_HASH,
                    block.chainid,
                    INTENT_EXECUTOR
                )
            );
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    /// @notice Validates every execution against the hardcoded registration and name-management action set.
    /// @dev Checks target, selector, value, and selected ABI arguments for each execution.
    ///      A default reverse name may be updated when the policy has a nonzero resolver and the
    ///      named account is the HCA owner. The owner's `addr.reverse` node may be claimed with
    ///      either a zero resolver or the session's bound resolver.
    /// @param account The HCA that executes the operation.
    /// @param owner The owner recorded for the HCA.
    /// @param allowedResolver The resolver bound to the enabled session.
    /// @param operationData The encoded ERC-7579 operation payload.
    function _checkRegistrationPolicy(
        address account,
        address owner,
        address allowedResolver,
        bytes calldata operationData
    )
        internal
        view
    {
        _checkRegistrationPolicy(
            account,
            owner,
            allowedResolver,
            operationData,
            GasRefund(address(0), 0, 0)
        );
    }

    /// @dev Applies the registration policy and any executor reimbursement constraints.
    function _checkRegistrationPolicy(
        address account,
        address owner,
        address allowedResolver,
        bytes calldata operationData,
        GasRefund memory gasRefund
    )
        internal
        view
    {
        if (operationData.length < 32) {
            revert InvalidOperationEncoding();
        }
        bytes32 operationMode = bytes32(operationData[:32]);
        if (
            operationMode != ERC7579_EMISSARY_EXECUTION_MODE &&
            operationMode != ERC7579_ERC1271_MODE &&
            operationMode != ERC7579_ERC1271_EMISSARY_EXECUTION_MODE
        ) {
            revert InvalidOperationEncoding();
        }

        Execution[] memory executions = abi.decode(operationData[32:], (Execution[]));
        _checkRegistrationExecutions(account, owner, allowedResolver, executions, gasRefund);
    }

    /// @dev Allows one exact session-enable call in the first policy-checked batch.
    function _checkInitialRegistrationPolicy(
        address account,
        address owner,
        bytes32 permissionId,
        SessionEnableProof memory proof,
        bytes calldata operationData,
        GasRefund memory gasRefund
    )
        internal
        view
    {
        if (operationData.length < 32 || !_isERC1271OperationMode(bytes32(operationData[:32]))) {
            revert InvalidOperationEncoding();
        }
        Execution[] memory executions = abi.decode(operationData[32:], (Execution[]));
        if (executions.length < 2) {
            revert PolicyRuleFailed();
        }

        bytes memory expectedCall =
            abi.encodeWithSelector(
                this.enableSessionWithRefund.selector,
                permissionId,
                proof.sessionKey,
                proof.validUntil,
                proof.resolver,
                proof.refundToken,
                proof.maxRefundExchangeRate,
                proof.maxRefundGasOverhead,
                proof.maxRefundAmount
            );
        uint256 enableIndex = type(uint256).max;
        for (uint256 i; i < executions.length; ++i) {
            if (executions[i].target != address(this)) {
                continue;
            }
            if (
                enableIndex != type(uint256).max ||
                executions[i].value != 0 ||
                keccak256(executions[i].callData) != keccak256(expectedCall)
            ) {
                revert PolicyRuleFailed();
            }
            enableIndex = i;
        }
        if (enableIndex == type(uint256).max) {
            revert PolicyRuleFailed();
        }

        (uint256 permitIndex, uint256 transferIndex) =
            _fundingCallIndexes(executions, account, owner, proof.refundToken);
        uint256 fundingCallCount = permitIndex == type(uint256).max ? 0 : 2;
        Execution[] memory remaining = new Execution[](executions.length - 1 - fundingCallCount);
        uint256 next;
        for (uint256 i; i < executions.length; ++i) {
            if (i != enableIndex && i != permitIndex && i != transferIndex) {
                remaining[next++] = executions[i];
            }
        }
        _checkRegistrationExecutions(account, owner, proof.resolver, remaining, gasRefund);
    }

    /// @dev Applies the fixed ENS policy to a decoded execution array.
    function _checkRegistrationExecutions(
        address account,
        address owner,
        address allowedResolver,
        Execution[] memory executions,
        GasRefund memory gasRefund
    )
        internal
        view
    {
        (address policyResolver, bool seenRegister) =
            _registrationResolver(executions, owner, allowedResolver);
        RegistrationPolicyState memory state;

        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            if (execution.value != 0) {
                revert PolicyRuleFailed();
            }

            bytes4 selector = _selector(execution.callData);

            if (selector == COMMIT_SELECTOR) {
                if (!_isAuthorizedRegistrar(execution.target)) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                continue;
            }

            if (selector == REGISTER_SELECTOR) {
                // The preceding registration scan verifies the target's live registrar role.
                state.usesResolver = true;
                if (policyResolver.code.length == 0 && !state.deploysResolver) {
                    revert PolicyRuleFailed();
                }
                continue;
            }

            if (policyResolver != address(0) && execution.target == policyResolver) {
                state.usesResolver = true;
                if (policyResolver.code.length == 0 && !state.deploysResolver) {
                    revert PolicyRuleFailed();
                }
                if (_checkResolverCall(execution.callData, owner)) {
                    state.grantsOwnerResolverRoles = true;
                }
                continue;
            }

            if (execution.target == DEFAULT_REVERSE_REGISTRAR_HCA_ADAPTER) {
                if (selector != SET_NAME_WITH_HCA_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                if (policyResolver == address(0)) {
                    revert PolicyRuleFailed();
                }
                address namedAccount = _readAddress(execution.callData, 4);
                if (namedAccount != owner) {
                    revert PolicyRuleFailed();
                }
                continue;
            }

            if (execution.target == REVERSE_REGISTRAR_HCA_ADAPTER) {
                if (selector != CLAIM_WITH_HCA_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                address claimedAccount = _readAddress(execution.callData, 4);
                if (claimedAccount != owner) {
                    revert PolicyRuleFailed();
                }
                address claimResolver = _readAddress(execution.callData, 4 + 32);
                if (claimResolver != address(0) && claimResolver != policyResolver) {
                    revert PolicyRuleFailed();
                }
                continue;
            }

            if (execution.target == PAYMENT_TOKEN || execution.target == SECONDARY_PAYMENT_TOKEN) {
                if (selector != APPROVE_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                _checkPaymentTokenApproval(execution.target, execution.callData, gasRefund);
                continue;
            }

            if (execution.target == VERIFIABLE_FACTORY) {
                if (selector != DEPLOY_PROXY_SELECTOR) {
                    revert ActionNotAllowed(execution.target, selector);
                }
                if (state.deploysResolver) {
                    revert PolicyRuleFailed();
                }
                _checkResolverDeployment(account, policyResolver, execution.callData);
                state.usesResolver = true;
                state.deploysResolver = true;
                continue;
            }

            revert ActionNotAllowed(execution.target, selector);
        }

        if (seenRegister && !state.grantsOwnerResolverRoles) {
            revert PolicyRuleFailed();
        }
        _checkResolverBinding(policyResolver, state);
    }

    /// @dev Finds the resolver used by every registration in a batch.
    /// @param executions The decoded operation batch.
    /// @param owner The owner that must receive each registration.
    /// @param allowedResolver The resolver bound to the enabled session.
    /// @return policyResolver The resolver that the policy permits for the batch.
    /// @return seenRegister Whether the batch contains a registration.
    function _registrationResolver(
        Execution[] memory executions,
        address owner,
        address allowedResolver
    )
        internal
        view
        returns (address policyResolver, bool seenRegister)
    {
        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            if (_selector(execution.callData) != REGISTER_SELECTOR) {
                continue;
            }
            if (!_isAuthorizedRegistrar(execution.target)) {
                revert ActionNotAllowed(execution.target, REGISTER_SELECTOR);
            }

            (address registrant, address resolver) = _registerFields(execution.callData);
            if (registrant != owner) {
                revert PolicyRuleFailed();
            }
            if (!seenRegister) {
                seenRegister = true;
                policyResolver = resolver;
            } else if (policyResolver != resolver) {
                revert PolicyRuleFailed();
            }
        }

        if (seenRegister) {
            if (allowedResolver != policyResolver) {
                revert PolicyRuleFailed();
            }
        } else {
            policyResolver = allowedResolver;
        }
    }

    /// @dev Validates an exact deployment of the resolver bound to the session.
    /// @param account The HCA that will call the factory.
    /// @param resolver The resolver address bound to the session.
    /// @param callData ABI-encoded `VerifiableFactory.deployProxy` call data.
    function _checkResolverDeployment(address account, address resolver, bytes memory callData)
        internal
        view
    {
        uint256 salt = _readUint(callData, 4 + 32);
        bytes[] memory setters = new bytes[](0);
        bytes memory expectedInitData =
            abi.encodeCall(
                IHCARegistrationResolver.initialize,
                (account, EACBaseRolesLib.ALL_ROLES, setters)
            );
        bytes memory expectedCallData =
            abi.encodeCall(
                IVerifiableFactory.deployProxy,
                (PERMITTED_RESOLVER_IMPL, salt, expectedInitData)
            );

        if (
            keccak256(callData) != keccak256(expectedCallData) ||
            _resolverAddress(account, salt) != resolver
        ) {
            revert PolicyRuleFailed();
        }
    }

    /// @dev Requires a used resolver to be an exact pending deployment or a verified proxy.
    /// @param resolver The resolver bound to the session.
    /// @param state The resolver-related state collected from the operation batch.
    function _checkResolverBinding(address resolver, RegistrationPolicyState memory state)
        internal
        view
    {
        if (!state.usesResolver) {
            return;
        }
        if (resolver == address(0)) {
            revert PolicyRuleFailed();
        }
        if (resolver.code.length == 0) {
            if (!state.deploysResolver) {
                revert PolicyRuleFailed();
            }
            return;
        }
        if (state.deploysResolver) {
            revert PolicyRuleFailed();
        }

        try IVerifiableFactory(VERIFIABLE_FACTORY).verifyContract(resolver) returns (
            address implementation
        ) {
            if (implementation != PERMITTED_RESOLVER_IMPL) {
                revert PolicyRuleFailed();
            }
        } catch {
            revert PolicyRuleFailed();
        }
    }

    /// @dev Computes the resolver proxy address for an HCA and user salt.
    /// @param account The HCA that deploys the resolver proxy.
    /// @param salt The user salt supplied to the VerifiableFactory.
    /// @return resolver The counterfactual resolver address.
    function _resolverAddress(address account, uint256 salt)
        internal
        view
        returns (address resolver)
    {
        bytes32 outerSalt = keccak256(abi.encode(account, salt));
        return
            Create2.computeAddress(
                outerSalt,
                keccak256(CloneProxyBytecode.creationCode(VERIFIABLE_PROXY_LOGIC, outerSalt)),
                VERIFIABLE_FACTORY
            );
    }

    /// @dev Allows payment approvals to registry-authorized registrars and exact, signed
    ///      executor-refund approvals.
    function _checkPaymentTokenApproval(
        address token,
        bytes memory callData,
        GasRefund memory gasRefund
    )
        internal
        view
    {
        address spender = _readAddress(callData, 4);
        if (_isAuthorizedRegistrar(spender)) {
            return;
        }
        if (
            spender != GAS_REFUND_PAYMASTER ||
            gasRefund.token != token ||
            _readUint(callData, 4 + 32) != gasRefund.overhead >> 128
        ) {
            revert PolicyRuleFailed();
        }
    }

    /// @dev Returns whether the pinned registry currently authorizes an account to register names.
    /// @param account The prospective registrar.
    /// @return authorized Whether the account holds the root registrar role.
    function _isAuthorizedRegistrar(address account) internal view returns (bool authorized) {
        return
            IPermissionedRegistry(ETH_REGISTRY).hasRootRoles(
                RegistryRolesLib.ROLE_REGISTRAR,
                account
            );
    }

    /// @dev Finds and checks an optional EIP-2612 funding pull into the HCA.
    ///      The permit and transfer must be adjacent, use the same amount, and consume the full
    ///      allowance that the owner gave to this HCA.
    function _fundingCallIndexes(
        Execution[] memory executions,
        address account,
        address owner,
        address token
    )
        internal
        pure
        returns (uint256 permitIndex, uint256 transferIndex)
    {
        permitIndex = type(uint256).max;
        transferIndex = type(uint256).max;
        uint256 permittedAmount;
        uint256 transferredAmount;

        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            if (execution.target != token) {
                continue;
            }
            bytes4 selector = _selector(execution.callData);
            if (selector == PERMIT_SELECTOR) {
                if (
                    permitIndex != type(uint256).max ||
                    execution.value != 0 ||
                    execution.callData.length != 4 + 7 * 32
                ) {
                    revert PolicyRuleFailed();
                }
                _requireArgAddress(execution.callData, 4, owner);
                _requireArgAddress(execution.callData, 4 + 32, account);
                permittedAmount = _readUint(execution.callData, 4 + 2 * 32);
                permitIndex = i;
            } else if (selector == TRANSFER_FROM_SELECTOR) {
                if (
                    transferIndex != type(uint256).max ||
                    execution.value != 0 ||
                    execution.callData.length != 4 + 3 * 32
                ) {
                    revert PolicyRuleFailed();
                }
                _requireArgAddress(execution.callData, 4, owner);
                _requireArgAddress(execution.callData, 4 + 32, account);
                transferredAmount = _readUint(execution.callData, 4 + 2 * 32);
                transferIndex = i;
            }
        }

        if (permitIndex == type(uint256).max && transferIndex == type(uint256).max) {
            return (permitIndex, transferIndex);
        }
        if (
            permitIndex == type(uint256).max ||
            transferIndex != permitIndex + 1 ||
            permittedAmount == 0 ||
            transferredAmount != permittedAmount
        ) {
            revert PolicyRuleFailed();
        }
    }

    /// @dev Reconstructs the Permit2 witness digest from the compact claim fields.
    function _permit2Digest(bytes calldata data, uint256 sourceChainId)
        internal
        pure
        returns (bytes32)
    {
        Permit2Fields memory claim = _decodePermit2Fields(data);

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
                    keccak256(abi.encode(TOKEN_TYPEHASH, claim.tokenOut, claim.amountOut))
                )
            );
        bytes32 targetHash =
            keccak256(
                abi.encode(
                    TARGET_TYPEHASH,
                    claim.recipient,
                    tokenOutHash,
                    claim.targetChainId,
                    claim.fillExpiry
                )
            );
        bytes32 mandateHash =
            keccak256(
                abi.encode(
                    MANDATE_TYPEHASH,
                    targetHash,
                    uint128(bytes16(data[298:314])),
                    bytes32(data[314:346]),
                    bytes32(data[346:378]),
                    bytes32(data[378:410])
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
            keccak256(abi.encode(PERMIT2_DOMAIN_TYPEHASH, PERMIT2_NAME_HASH, sourceChainId, PERMIT2));
        return MessageHashUtils.toTypedDataHash(domainSeparator, permitHash);
    }

    /// @dev Decodes the compact fields used by the Permit2 destination policy.
    function _decodePermit2Fields(bytes calldata data)
        internal
        pure
        returns (Permit2Fields memory claim)
    {
        claim.spender = address(bytes20(data[0:20]));
        claim.nonce = uint256(bytes32(data[20:52]));
        claim.deadline = uint256(bytes32(data[52:84]));
        claim.sourceToken = address(uint160(uint256(bytes32(data[85:117]))));
        claim.sourceAmount = uint256(bytes32(data[117:149]));
        claim.recipient = address(bytes20(data[149:169]));
        claim.targetChainId = uint256(bytes32(data[169:201]));
        claim.fillExpiry = uint256(bytes32(data[201:233]));
        claim.tokenOut = address(uint160(uint256(bytes32(data[234:266]))));
        claim.amountOut = uint256(bytes32(data[266:298]));
    }

    /// @dev Hashes the fixed HCA fields stored in the standard Smart Session salt.
    function _sessionAuthorizationSalt(SessionEnableProof memory proof)
        internal
        pure
        returns (bytes32)
    {
        return
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
    }

    /// @dev Returns the standard one-of-one Ownable session-validator initialization data.
    function _sessionValidatorInitData(address sessionKey) internal pure returns (bytes memory) {
        address[] memory owners = new address[](1);
        owners[0] = sessionKey;
        return abi.encode(uint256(1), owners);
    }

    /// @dev Checks an executor reimbursement against the limits approved for a session.
    function _checkGasRefund(SessionConfig memory config, GasRefund memory gasRefund) internal pure {
        if (gasRefund.token == address(0)) {
            if (gasRefund.exchangeRate != 0 || gasRefund.overhead != 0) {
                revert GasRefundNotAllowed();
            }
            return;
        }
        uint256 refundAmount = gasRefund.overhead >> 128;
        uint256 gasOverhead = uint128(gasRefund.overhead);
        if (
            gasRefund.token != config.refundToken ||
            gasRefund.exchangeRate == 0 ||
            gasRefund.exchangeRate > config.maxRefundExchangeRate ||
            refundAmount == 0 ||
            refundAmount > config.maxRefundAmount ||
            gasOverhead > config.maxRefundGasOverhead
        ) {
            revert GasRefundNotAllowed();
        }
    }

    /// @dev Hashes the encoded ERC-7579 operation exactly as IntentExecutor does.
    function _operationHash(bytes calldata operationData) internal pure returns (bytes32) {
        if (operationData.length < 32) {
            revert InvalidOperationEncoding();
        }

        bytes32 operationMode = bytes32(operationData[:32]);
        if (!_isERC1271OperationMode(operationMode)) {
            revert InvalidOperationEncoding();
        }

        Execution[] memory executions = abi.decode(operationData[32:], (Execution[]));
        bytes32[] memory executionHashes = new bytes32[](executions.length);
        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            executionHashes[i] = keccak256(
                abi.encode(
                    EXECUTION_TYPEHASH,
                    execution.target,
                    execution.value,
                    keccak256(execution.callData)
                )
            );
        }
        return
            keccak256(
                abi.encode(OP_TYPEHASH, operationMode, keccak256(abi.encodePacked(executionHashes)))
            );
    }

    /// @dev Returns true for an ERC-1271 operation mode that this validator supports.
    function _isERC1271OperationMode(bytes32 operationMode) internal pure returns (bool) {
        return
            operationMode == ERC7579_ERC1271_MODE ||
            operationMode == ERC7579_ERC1271_EMISSARY_EXECUTION_MODE;
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
    ///      A role call must grant every root role to the HCA owner.
    /// @param callData ABI-encoded resolver call data.
    /// @param owner The owner recorded for the HCA.
    /// @return grantsOwnerResolverRoles Whether the call grants root resolver control to the owner.
    function _checkResolverCall(bytes memory callData, address owner)
        internal
        pure
        returns (bool grantsOwnerResolverRoles)
    {
        bytes4 selector = _selector(callData);
        if (selector == MULTICALL_SELECTOR) {
            bytes[] memory calls = abi.decode(_callArgs(callData), (bytes[]));
            return _checkResolverCalls(calls, owner);
        }
        if (selector == MULTICALL_WITH_NODE_CHECK_SELECTOR) {
            (, bytes[] memory calls) = abi.decode(_callArgs(callData), (bytes32, bytes[]));
            return _checkResolverCalls(calls, owner);
        }
        if (selector == AUTHORIZE_NAME_ROLES_SELECTOR) {
            bytes memory expectedCallData =
                abi.encodeCall(
                    IHCARegistrationResolver.authorizeNameRoles,
                    (hex"00", EACBaseRolesLib.ALL_ROLES, owner, true)
                );
            if (keccak256(callData) != keccak256(expectedCallData)) {
                revert PolicyRuleFailed();
            }
            return true;
        }
        if (_isResolverRecordSelector(selector)) {
            return false;
        }
        revert ActionNotAllowed(address(0), selector);
    }

    /// @notice Validates nested resolver calls.
    /// @dev Recursively validates each encoded resolver call.
    /// @param calls ABI-encoded resolver calls.
    /// @param owner The owner recorded for the HCA.
    /// @return grantsOwnerResolverRoles Whether a nested call grants root resolver control.
    function _checkResolverCalls(bytes[] memory calls, address owner)
        internal
        pure
        returns (bool grantsOwnerResolverRoles)
    {
        for (uint256 i; i < calls.length; ++i) {
            if (_checkResolverCall(calls[i], owner)) {
                grantsOwnerResolverRoles = true;
            }
        }
    }

    /// @notice Reads the fields relevant to the registration policy from a register call.
    /// @dev Reads only the needed ABI head words instead of decoding the full register tuple.
    /// @param callData ABI-encoded register call data.
    /// @return registrant The owner argument of the register call.
    /// @return resolver The resolver argument of the register call.
    function _registerFields(bytes memory callData)
        internal
        pure
        returns (address registrant, address resolver)
    {
        registrant = _readAddress(callData, 4 + 32);
        resolver = _readAddress(callData, 4 + 128);
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
            revert InvalidSigner();
        }
        ECDSA.RecoverError error;
        (signer, error, ) = ECDSA.tryRecover(digest, v, r, s);
        if (error != ECDSA.RecoverError.NoError) {
            revert InvalidSigner();
        }
    }

    /// @dev Checks raw and EIP-191 UserOperation signatures without reverting on invalid input.
    function _isValidUserOpSignature(address expectedOwner, bytes32 digest, bytes calldata signature)
        internal
        pure
        returns (bool)
    {
        if (signature.length != ECDSA_SIGNATURE_LENGTH) {
            return false;
        }

        bytes32 r;
        bytes32 s;
        uint8 v;
        assembly ("memory-safe") {
            r := calldataload(signature.offset)
            s := calldataload(add(signature.offset, 0x20))
            v := byte(0, calldataload(add(signature.offset, 0x40)))
        }

        bool explicitEthSigned = v == 31 || v == 32;
        if (explicitEthSigned) {
            v -= 4;
        } else if (v < 27) {
            v += 27;
        }
        if (v != 27 && v != 28) {
            return false;
        }

        address signer;
        ECDSA.RecoverError error;
        if (!explicitEthSigned) {
            (signer, error, ) = ECDSA.tryRecover(digest, v, r, s);
            if (error == ECDSA.RecoverError.NoError && signer == expectedOwner) {
                return true;
            }
        }

        (signer, error, ) = ECDSA.tryRecover(
            MessageHashUtils.toEthSignedMessageHash(digest),
            v,
            r,
            s
        );
        return error == ECDSA.RecoverError.NoError && signer == expectedOwner;
    }
}
