// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Execution} from "nexus/types/DataTypes.sol";
import {ERC1271_MAGICVALUE} from "nexus/types/Constants.sol";

import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {HCAOperationHashLib} from "~src/hca/libraries/HCAOperationHashLib.sol";
import {HCASmartSessionLib} from "~src/hca/libraries/HCASmartSessionLib.sol";
import {IETHRegistrar} from "~src/registrar/interfaces/IETHRegistrar.sol";
import {IRentPriceOracle} from "~src/registrar/interfaces/IRentPriceOracle.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";

import {MockStandaloneHCA} from "../../../mocks/MockStandaloneHCAStack.sol";
import {DeployedIntentExecutor} from "../executor/DeployedIntentExecutor.sol";

/// @title Owner Session Registry Response Model
/// @notice Supplies independently configured registrar-role answers to the production validator.
/// @dev Models the registry interface only; registry authorization transitions are outside this suite.
contract OwnerSessionRegistryModel {
    mapping(address candidate => bool authorized) private _authorized;

    /// @notice Configures a registrar-role response.
    function setAuthorized(address candidate, bool authorized) external {
        _authorized[candidate] = authorized;
    }

    /// @notice Answers only the registrar-role query used by the policy.
    function hasRootRoles(uint256 roles, address candidate) external view returns (bool) {
        return roles == RegistryRolesLib.ROLE_REGISTRAR && _authorized[candidate];
    }
}


/// @title Owner Session Rent Oracle Response Model
/// @notice Supplies payment-token support independently of the validator implementation.
contract OwnerSessionOracleModel {
    /// @notice The configured oracle response is unavailable.
    error OracleUnavailable();

    mapping(address token => bool supported) private _supported;
    bool private _reverts;

    /// @notice Configures token support and whether the oracle is available.
    function configure(address token, bool supported, bool reverts_) external {
        _supported[token] = supported;
        _reverts = reverts_;
    }

    /// @notice Implements the token-support query with the configured response.
    function isPaymentToken(IERC20 token) external view returns (bool) {
        if (_reverts)
            revert OracleUnavailable();
        return _supported[address(token)];
    }
}


/// @title Owner Session Registrar Response Model
/// @notice Models discovery of a registrar's current rent oracle.
contract OwnerSessionRegistrarModel {
    /// @notice The configured registrar response is unavailable.
    error RegistrarUnavailable();

    address private _oracle;
    bool private _reverts;

    /// @notice Configures oracle discovery and its availability.
    function configure(address oracle, bool reverts_) external {
        _oracle = oracle;
        _reverts = reverts_;
    }

    /// @notice Returns the configured oracle, or reverts when discovery is unavailable.
    function rentPriceOracle() external view returns (IRentPriceOracle) {
        if (_reverts)
            revert RegistrarUnavailable();
        return IRentPriceOracle(_oracle);
    }
}


/// @title Owner Session Resolver Code Model
/// @notice Gives a resolver address nonempty code without modeling resolver execution.
/// @dev The validator only inspects target code presence and factory verification in these checks.
contract OwnerSessionResolverModel {
    /// @notice Returns a marker so the model has runtime code.
    function marker() external pure returns (bool) {
        return true;
    }
}


/// @title Owner Session Factory Response Model
/// @notice Models factory introspection and resolver implementation verification.
/// @dev No deployment is executed by this model; deployment-policy proofs check encoded requests.
contract OwnerSessionFactoryModel {
    /// @notice The configured factory response is unavailable.
    error FactoryUnavailable();

    address private immutable _PROXY_LOGIC;
    mapping(address resolver => address implementation) private _implementation;
    bool private _reverts;

    /// @param proxyLogic_ The proxy logic used for counterfactual address derivation.
    constructor(address proxyLogic_) {
        _PROXY_LOGIC = proxyLogic_;
    }

    /// @notice Returns the configured factory proxy logic through the production getter signature.
    function proxyLogic() external view returns (address) {
        return _PROXY_LOGIC;
    }

    /// @notice Configures the implementation reported for a resolver.
    function configure(address resolver, address implementation, bool reverts_) external {
        _implementation[resolver] = implementation;
        _reverts = reverts_;
    }

    /// @notice Implements factory verification with an independently configured result.
    function verifyContract(address resolver) external view returns (address) {
        if (_reverts)
            revert FactoryUnavailable();
        return _implementation[resolver];
    }
}


/// @title Owner Session Wire Codec
/// @notice Exposes inherited wire constants and builds EIP-712 fixtures without replacing the subject.
/// @dev The verification subject is a separate, exact production-validator deployment. This helper
///      introduces no override and supplies no policy or authorization decisions to that deployment.
contract OwnerSessionWireCodec is HCAOwnerAndSessionValidator {
    /// @param factory A factory response model needed by the inherited constructor.
    constructor(address factory)
        HCAOwnerAndSessionValidator(
            address(0),
            address(0),
            address(0),
            address(0),
            factory,
            address(0),
            address(0)
        )
    {}

    /// @notice Returns the production same-chain session envelope discriminator.
    function refundMode() external pure returns (bytes1) {
        return FIXED_SESSION_REFUND_ENABLE_MODE;
    }

    /// @notice Returns the production Permit2 session envelope discriminator.
    function permit2Mode() external pure returns (bytes1) {
        return FIXED_SESSION_PERMIT2_ENABLE_MODE;
    }

    /// @notice Returns the production Permit2 verifying contract used in signed claim domains.
    function permit2Address() external pure returns (address) {
        return PERMIT2;
    }

    /// @notice Computes a refund struct hash directly from its ABI fields, including an all-zero refund.
    function refundStructHash(GasRefund memory refund) external pure returns (bytes32) {
        return
            keccak256(
                abi.encode(GAS_REFUND_TYPEHASH, refund.token, refund.exchangeRate, refund.overhead)
            );
    }

    /// @notice Returns the production precomputed all-zero refund hash.
    function noRefundHash() external pure returns (bytes32) {
        return NO_GAS_REFUND_HASH;
    }

    /// @notice Builds the public IntentExecutor EIP-712 message from its independently supplied fields.
    function intentDigest(
        address account,
        uint256 nonce,
        bytes32 operationHash,
        GasRefund memory refund,
        uint256 chainId,
        address executor
    )
        external
        pure
        returns (bytes32)
    {
        bytes32 refundHash = refund.token == address(0) &&
        refund.exchangeRate == 0 &&
        refund.overhead == 0
        ? NO_GAS_REFUND_HASH
        : keccak256(
            abi.encode(GAS_REFUND_TYPEHASH, refund.token, refund.exchangeRate, refund.overhead)
        );
        bytes32 domain =
            keccak256(
                abi.encode(
                    EIP712_DOMAIN_TYPEHASH,
                    INTENT_EXECUTOR_NAME_HASH,
                    INTENT_EXECUTOR_VERSION_HASH,
                    chainId,
                    executor
                )
            );
        bytes32 message =
            keccak256(
                abi.encode(SINGLE_CHAIN_OPS_TYPEHASH, account, nonce, operationHash, refundHash)
            );
        return MessageHashUtils.toTypedDataHash(domain, message);
    }
}


/// @title Owner Session Public-API Proof Fixture
/// @notice Constructs complete owner-authorized envelopes for the unmodified production validator.
/// @dev Each check describes a bounded call shape, not an arbitrary-history invariant. The account
///      owner/nonce, registry roles, oracle answers, and factory verification are interface models.
///      Halmos models signing, recovery, and hashing symbolically; these checks do not prove the
///      cryptographic primitives. Every signing call restates canonical signature ranges and the
///      signing oracle's recovery guarantee because Halmos shares its signature cache across paths.
///      These assumptions constrain only generated fixture signatures, never the subject's result.
///      Sender and EIP-712 domain use the pinned mainnet/Sepolia IntentExecutor proxy address;
///      component checks model its call boundary. The refund paymaster is an explicit policy fixture.
abstract contract OwnerSessionFixture is Test {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant SESSION_KEY = 0x5E5510;
    uint256 internal constant OTHER_KEY = 0xBAD;

    address internal constant INTENT_EXECUTOR = DeployedIntentExecutor.PROXY;
    address internal constant DEFAULT_REVERSE_ADAPTER = address(0xDEFA);
    address internal constant REVERSE_ADAPTER = address(0xBEEF);
    address internal constant PAYMENT_TOKEN = address(0xC011);
    address internal constant PAYMASTER = address(0xC0FFEE);
    address internal constant RESOLVER_IMPLEMENTATION = address(0xFACE);

    HCAOwnerAndSessionValidator internal validator;
    OwnerSessionWireCodec internal codec;
    MockStandaloneHCA internal account;
    OwnerSessionRegistryModel internal registry;
    OwnerSessionFactoryModel internal factory;
    OwnerSessionRegistrarModel internal registrar;
    OwnerSessionRegistrarModel internal secondRegistrar;
    OwnerSessionOracleModel internal oracle;
    OwnerSessionResolverModel internal resolver;
    address internal owner;
    address internal sessionKey;

    struct Envelope {
        bytes32 digest;
        bytes data;
    }

    /// @notice Deploys the exact production validator with explicit external-interface models.
    function setUp() public virtual {
        owner = vm.addr(OWNER_KEY);
        sessionKey = vm.addr(SESSION_KEY);
        vm.assume(owner != address(0));
        vm.assume(sessionKey != address(0));
        vm.assume(owner != sessionKey);
        vm.assume(vm.addr(OTHER_KEY) != owner);
        vm.assume(vm.addr(OTHER_KEY) != sessionKey);
        account = new MockStandaloneHCA(owner);
        registry = new OwnerSessionRegistryModel();
        factory = new OwnerSessionFactoryModel(address(0xFACADE));
        registrar = new OwnerSessionRegistrarModel();
        secondRegistrar = new OwnerSessionRegistrarModel();
        oracle = new OwnerSessionOracleModel();
        resolver = new OwnerSessionResolverModel();
        registry.setAuthorized(address(registrar), true);
        registry.setAuthorized(address(secondRegistrar), true);
        registrar.configure(address(oracle), false);
        secondRegistrar.configure(address(oracle), false);
        oracle.configure(PAYMENT_TOKEN, true, false);
        factory.configure(address(resolver), RESOLVER_IMPLEMENTATION, false);
        validator = new HCAOwnerAndSessionValidator(
            DEFAULT_REVERSE_ADAPTER,
            REVERSE_ADAPTER,
            RESOLVER_IMPLEMENTATION,
            address(registry),
            address(factory),
            INTENT_EXECUTOR,
            PAYMASTER
        );
        codec = new OwnerSessionWireCodec(address(factory));
    }

    /// @dev Returns a reusable authorization with permissive finite refund bounds.
    function _proof()
        internal
        view
        returns (HCAOwnerAndSessionValidator.SessionEnableProof memory proof)
    {
        proof.sessionKey = sessionKey;
        proof.validUntil = type(uint48).max;
        proof.sessionNonce = account.sessionNonce();
        proof.resolver = address(resolver);
        proof.refundToken = PAYMENT_TOKEN;
        proof.maxRefundExchangeRate = type(uint96).max;
        proof.maxRefundGasOverhead = type(uint48).max;
        proof.maxRefundAmount = type(uint96).max;
    }

    /// @dev Returns a no-refund intent fixture.
    function _noRefund() internal pure returns (HCAOwnerAndSessionValidator.GasRefund memory) {
        return HCAOwnerAndSessionValidator.GasRefund(address(0), 0, 0);
    }

    /// @dev Restates the signing oracle's canonicality and recovery guarantees on every path.
    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vm.assume(v == 27 || v == 28);
        vm.assume(uint256(r) > 0 && uint256(r) < SECP256K1_ORDER);
        vm.assume(uint256(s) > 0 && uint256(s) <= SECP256K1_ORDER / 2);
        vm.assume(ecrecover(digest, v, r, s) == vm.addr(key));
        return abi.encodePacked(r, s, v);
    }

    /// @dev Builds the independently ABI-encoded operation hash for a fixed execution array.
    function _operationHash(bytes32 mode, Execution[] memory executions)
        internal
        pure
        returns (bytes32)
    {
        bytes32[] memory hashes = new bytes32[](executions.length);
        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            hashes[i] = keccak256(
                abi.encode(
                    HCAOperationHashLib.EXECUTION_TYPEHASH,
                    execution.target,
                    execution.value,
                    keccak256(execution.callData)
                )
            );
        }
        return
            keccak256(
                abi.encode(
                    HCAOperationHashLib.OPERATION_TYPEHASH,
                    mode,
                    keccak256(abi.encodePacked(hashes))
                )
            );
    }

    /// @dev Encodes the fixed zero-value batch in the production packed wire format.
    function _encode(bytes32 mode, Execution[] memory executions)
        internal
        pure
        returns (bytes memory data)
    {
        data = abi.encodePacked(bytes2(mode), uint8(executions.length));
        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            assert(execution.value == 0);
            data = bytes.concat(
                data,
                abi.encodePacked(
                    execution.target,
                    uint24(execution.callData.length),
                    execution.callData
                )
            );
        }
    }

    /// @dev Builds a single-chain owner proof using production authorization-hash primitives.
    function _packedProof(
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof,
        address authorizedAccount,
        uint64 authorizedChain,
        uint256 signingKey
    )
        internal
        pure
        returns (bytes32 permissionId, bytes memory packed)
    {
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
        bytes32 sessionDigest;
        (permissionId, sessionDigest) = HCASmartSessionLib.authorizationHashes(
            authorizedAccount,
            proof.sessionKey,
            salt
        );
        bytes32[] memory hashes = new bytes32[](1);
        hashes[0] = HCASmartSessionLib.chainSessionHash(authorizedChain, sessionDigest);
        packed = bytes.concat(
            _packHeader(proof, 1),
            abi.encodePacked(authorizedChain, sessionDigest),
            _sign(signingKey, HCASmartSessionLib.multiChainDigest(hashes))
        );
    }

    /// @dev Encodes a proof header without introducing an alternate policy implementation.
    function _packHeader(HCAOwnerAndSessionValidator.SessionEnableProof memory proof, uint8 count)
        internal
        pure
        returns (bytes memory)
    {
        return
            abi.encodePacked(
                proof.sessionKey,
                proof.validUntil,
                proof.sessionNonce,
                proof.resolver,
                proof.refundToken,
                proof.maxRefundExchangeRate,
                proof.maxRefundGasOverhead,
                proof.maxRefundAmount,
                proof.sessionToEnableIndex,
                count
            );
    }

    /// @dev Signs a complete same-chain operation containing one owner-authorization chain entry.
    function _envelope(
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof,
        Execution[] memory executions,
        uint256 nonce,
        HCAOwnerAndSessionValidator.GasRefund memory refund
    )
        internal
        view
        returns (Envelope memory envelope)
    {
        bytes32 mode = HCAOperationHashLib.ERC7579_ERC1271_MODE;
        (bytes32 permissionId, bytes memory packed) =
            _packedProof(proof, address(account), uint64(block.chainid), OWNER_KEY);
        envelope.digest = codec.intentDigest(
            address(account),
            nonce,
            _operationHash(mode, executions),
            refund,
            block.chainid,
            INTENT_EXECUTOR
        );
        envelope.data = _refundEnvelope(
            permissionId,
            packed,
            nonce,
            refund,
            _encode(mode, executions),
            envelope.digest,
            SESSION_KEY
        );
    }

    /// @dev Encodes an owner proof, refund fields, packed operation, and session signature.
    function _refundEnvelope(
        bytes32 permissionId,
        bytes memory packed,
        uint256 nonce,
        HCAOwnerAndSessionValidator.GasRefund memory refund,
        bytes memory operation,
        bytes32 digest,
        uint256 signingKey
    )
        internal
        view
        returns (bytes memory)
    {
        return
            bytes.concat(
                abi.encodePacked(codec.refundMode(), permissionId, packed, nonce),
                abi.encodePacked(
                    refund.token,
                    uint96(refund.exchangeRate),
                    uint96(refund.overhead >> 128),
                    uint48(uint128(refund.overhead))
                ),
                operation,
                _sign(signingKey, digest)
            );
    }

    /// @dev Returns a single commit action with a symbolic commitment.
    function _commit(bytes32 commitment) internal view returns (Execution[] memory executions) {
        executions = new Execution[](1);
        executions[0] = Execution(
            address(registrar),
            0,
            abi.encodeCall(IETHRegistrar.commit, (commitment))
        );
    }

    /// @dev Returns one execution without invoking the target.
    function _one(address target, bytes memory callData)
        internal
        pure
        returns (Execution[] memory executions)
    {
        executions = new Execution[](1);
        executions[0] = Execution(target, 0, callData);
    }

    /// @dev Calls the exact production ERC-1271 entry point from the account interface model.
    function _submit(bytes32 digest, bytes memory data)
        internal
        returns (bool success, bytes memory result)
    {
        vm.prank(address(account));
        return
            address(validator).staticcall(
                abi.encodeCall(
                    HCAOwnerAndSessionValidator.isValidSignatureWithSender,
                    (INTENT_EXECUTOR, digest, data)
                )
            );
    }

    /// @dev Requires successful validation and the complete ERC-1271 result.
    function _accept(Envelope memory envelope) internal {
        (bool success, bytes memory result) = _submit(envelope.digest, envelope.data);
        assert(success);
        assert(result.length == 32);
        assert(abi.decode(result, (bytes4)) == ERC1271_MAGICVALUE);
    }

    /// @dev Requires a concrete revert selector instead of treating a revert as a discarded proof path.
    function _reject(Envelope memory envelope, bytes4 expectedSelector) internal {
        (bool success, bytes memory result) = _submit(envelope.digest, envelope.data);
        assert(!success);
        assert(result.length >= 4);
        assert(bytes4(result) == expectedSelector);
    }
}
