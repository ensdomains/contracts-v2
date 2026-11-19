// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// solhint-disable private-vars-leading-underscore, func-name-mixedcase

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {Execution} from "nexus/types/DataTypes.sol";
import {ERC1271_MAGICVALUE} from "nexus/types/Constants.sol";

import {
    HCAFundingSessionValidator,
    IRhinestoneClaimRouter
} from "~src/hca/HCAFundingSessionValidator.sol";
import {HCAPermit2Lib} from "~src/hca/libraries/HCAPermit2Lib.sol";
import {HCAOperationHashLib} from "~src/hca/libraries/HCAOperationHashLib.sol";
import {HCASignatureLib} from "~src/hca/libraries/HCASignatureLib.sol";
import {HCASmartSessionLib} from "~src/hca/libraries/HCASmartSessionLib.sol";

import {DeployedIntentExecutor} from "../executor/DeployedIntentExecutor.sol";

/// @notice Models only the configured claim-router response used by funding validation.
/// @dev Token transfers, Permit2 nonce consumption, and bridge execution are outside this fixture.
contract HCAFundingClaimRouter is IRhinestoneClaimRouter {
    /// @notice The adapter returned for the configured route.
    address public adapter;

    bytes2 private _version;
    bytes4 private _selector;
    bool private _fails;

    /// @notice The modeled router is unavailable or the requested route differs.
    error RouterUnavailable();

    /// @notice Configures the route observed by the production validator.
    function configure(bytes2 version, bytes4 selector, address activeAdapter) external {
        _version = version;
        _selector = selector;
        adapter = activeAdapter;
    }

    /// @notice Changes the active adapter without changing an installed session.
    function setAdapter(address activeAdapter) external {
        adapter = activeAdapter;
    }

    /// @notice Controls a modeled router failure.
    function setFailure(bool fails) external {
        _fails = fails;
    }

    /// @notice Resolves exactly the route configured from production constants.
    function getClaimAdapter(bytes2 version, bytes4 selector)
        external
        view
        returns (address, bytes12)
    {
        if (_fails || version != _version || selector != _selector) {
            revert RouterUnavailable();
        }
        return (adapter, bytes12(0));
    }
}


/// @notice Provides calldata access to the production claim encoder for fixture construction.
/// @dev This contract is not the validation target and does not replace any policy check.
contract HCAFundingClaimCodec {
    /// @notice Computes the claim digest using the production Permit2 domain and field encoding.
    function digest(bytes calldata claim, uint256 chainId, address permit2)
        external
        pure
        returns (bytes32)
    {
        return HCAPermit2Lib.digest(claim, HCAPermit2Lib.decode(claim), chainId, permit2);
    }
}


/// @notice Shared signed-envelope fixture for public-API funding validator proofs.
/// @dev Bounds are one selected chain unless a check explicitly constructs two, canonical fixed-size
///      ECDSA signatures, and zero to three fixed-shape source calls. Scalar arguments retain their
///      full Solidity domains unless a check states a precondition. The validator is deployed
///      unchanged. Keccak and ECDSA use Halmos's cryptographic abstraction; this suite proves policy
///      and state transitions under that abstraction, not cryptographic hardness. Generated
///      signatures are restricted to canonical low-s outputs, as returned by concrete vm.sign.
///      The signing helper explicitly reinstates the sign-to-recover axiom on every path because
///      Halmos's signature cache is shared between paths while its constraints are path-local.
///      The configured executor identity is the pinned mainnet and Sepolia proxy; component
///      validation does not invoke its runtime. End-to-end executor checks use a separate fixture.
///      Session validation is read-only: Permit2 replay protection, ERC20 execution, approvals,
///      token permit signatures, and successful bridge delivery are not claimed by these checks.
abstract contract HCAFundingFixture is Test {
    /// @notice Signed material submitted through the production ERC-1271 validator entry point.
    struct FundingEnvelope {
        bytes32 digest;
        bytes claim;
        bytes operation;
        bytes data;
    }

    uint256 internal constant OWNER_PRIVATE_KEY = 0xA11CE;
    uint256 internal constant SESSION_PRIVATE_KEY = 0x5E5510;
    uint256 internal constant START_TIME = 1_000_000;
    uint48 internal constant SESSION_EXPIRY = 2_000_000;
    uint64 internal constant SOURCE_CHAIN = 84_532;
    uint64 internal constant DESTINATION_CHAIN = 11_155_111;
    uint96 internal constant SOURCE_CAP = 1_000_000;
    uint96 internal constant DESTINATION_CAP = 2_000_000;
    address internal constant ACCOUNT = address(0xA000);
    address internal constant OTHER_ACCOUNT = address(0xA001);
    address internal constant SOURCE_TOKEN = address(0xB000);
    address internal constant DESTINATION_TOKEN = address(0xB001);
    address internal constant RECIPIENT = address(0xC000);
    address internal constant EXECUTOR = DeployedIntentExecutor.PROXY;
    address internal constant PERMIT2 = address(0xD001);
    address internal constant ADAPTER = address(0xD002);

    // This wire mode is internal in production and cannot be referenced through its contract namespace.
    bytes1 internal constant FUNDING_MODE = 0x04;
    uint256 internal constant OWNER_SIGNATURE_OFFSET =
        HCASmartSessionLib.ENABLE_PREFIX_LENGTH + 2 + HCASmartSessionLib.AUTHORIZATION_ENTRY_LENGTH;
    uint256 internal constant SESSION_SIGNATURE_OFFSET =
        OWNER_SIGNATURE_OFFSET + HCASignatureLib.SIGNATURE_LENGTH;
    uint256 internal constant CLAIM_OFFSET =
        SESSION_SIGNATURE_OFFSET + HCASignatureLib.SIGNATURE_LENGTH;

    HCAFundingSessionValidator internal validator;
    HCAFundingClaimRouter internal router;
    HCAFundingClaimCodec internal codec;
    HCAFundingSessionValidator.SessionConfig internal config;
    address internal owner;
    address internal sessionKey;

    /// @notice Installs a reachable, live funding session through its real installation entry point.
    function setUp() public virtual {
        vm.warp(START_TIME);
        vm.chainId(SOURCE_CHAIN);
        owner = vm.addr(OWNER_PRIVATE_KEY);
        sessionKey = vm.addr(SESSION_PRIVATE_KEY);
        vm.assume(owner != address(0));
        vm.assume(sessionKey != address(0));
        vm.assume(owner != sessionKey);
        router = new HCAFundingClaimRouter();
        validator = new HCAFundingSessionValidator(EXECUTOR, PERMIT2, address(router));
        codec = new HCAFundingClaimCodec();
        router.configure(
            validator.RHINESTONE_PROTOCOL_VERSION(),
            validator.ACROSS_PERMIT2_CLAIM_SELECTOR(),
            ADAPTER
        );
        config = HCAFundingSessionValidator.SessionConfig({permissionId: bytes32(0), owner: owner, validUntil: SESSION_EXPIRY, sessionKey: sessionKey, sourceToken: SOURCE_TOKEN, destinationRecipient: RECIPIENT, destinationToken: DESTINATION_TOKEN, destinationChainId: DESTINATION_CHAIN, maxSourceAmount: SOURCE_CAP, maxDestinationAmount: DESTINATION_CAP});
        (config.permissionId, ) = HCASmartSessionLib.authorizationHashes(
            ACCOUNT,
            sessionKey,
            _authorizationSalt(config)
        );
        (bool success, ) = _install(ACCOUNT, config);
        assert(success);
        assert(validator.isInitialized(ACCOUNT));
    }

    /// @notice Attempts installation as the specified account and preserves the call result.
    function _install(address account, HCAFundingSessionValidator.SessionConfig memory session)
        internal
        returns (bool success, bytes memory result)
    {
        vm.prank(account);
        return address(validator).call(abi.encodeCall(validator.onInstall, (abi.encode(session))));
    }

    /// @notice Attempts removal as the specified account and preserves the call result.
    function _uninstall(address account) internal returns (bool success, bytes memory result) {
        vm.prank(account);
        return address(validator).call(abi.encodeCall(validator.onUninstall, (bytes(""))));
    }

    /// @notice Reads the complete public session snapshot for rollback and isolation assertions.
    function _sessionHash(address account) internal view returns (bytes32) {
        return keccak256(abi.encode(validator.sessionConfig(account)));
    }

    /// @notice Replaces the fixture session using only public lifecycle entry points.
    function _replaceConfig(HCAFundingSessionValidator.SessionConfig memory replacement) internal {
        (bool removed, ) = _uninstall(ACCOUNT);
        assert(removed);
        (bool installed, ) = _install(ACCOUNT, replacement);
        assert(installed);
        config = replacement;
    }

    /// @notice Constructs a baseline fixed-route claim with caller-selected amount and nonce.
    function _claim(uint256 sourceAmount, uint256 nonce)
        internal
        view
        returns (HCAPermit2Lib.Claim memory claim)
    {
        claim = HCAPermit2Lib.Claim({spender: router.adapter(), nonce: nonce, deadline: config.validUntil, sourceToken: config.sourceToken, sourceAmount: sourceAmount, recipient: config.destinationRecipient, targetChainId: config.destinationChainId, fillExpiry: config.validUntil, tokenOut: config.destinationToken, amountOut: 1});
    }

    /// @notice Encodes the fixed claim layout with one input token and one output token.
    function _encodeClaim(HCAPermit2Lib.Claim memory claim, bytes32 operationHash)
        internal
        pure
        returns (bytes memory)
    {
        return
            bytes.concat(
                abi.encodePacked(
                    claim.spender,
                    claim.nonce,
                    claim.deadline,
                    uint8(1),
                    bytes32(uint256(uint160(claim.sourceToken))),
                    claim.sourceAmount
                ),
                abi.encodePacked(
                    claim.recipient,
                    claim.targetChainId,
                    claim.fillExpiry,
                    uint8(1),
                    bytes32(uint256(uint160(claim.tokenOut))),
                    claim.amountOut
                ),
                abi.encodePacked(uint128(0), operationHash, bytes32(0), bytes32(0))
            );
    }

    /// @notice Builds an independent operation struct hash from the supplied execution tuples.
    /// @dev Production hashing decodes compact bytes in assembly; this uses ABI tuple hashing.
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

    /// @notice Packs execution targets and calldata using the production zero-value wire format.
    /// @dev The wire format contains no value field; nonzero tuple values only affect the separate
    ///      independently constructed hash, allowing a check of value commitment mismatch.
    function _packOperation(bytes32 mode, Execution[] memory executions)
        internal
        pure
        returns (bytes memory packed)
    {
        packed = abi.encodePacked(bytes2(mode), uint8(executions.length));
        for (uint256 i; i < executions.length; ++i) {
            bytes memory callData = executions[i].callData;
            packed = bytes.concat(
                packed,
                abi.encodePacked(executions[i].target, uint24(callData.length), callData)
            );
        }
    }

    /// @notice Creates an owner-to-account transfer using the configured source token.
    function _transfer(uint256 amount) internal view returns (Execution memory) {
        return
            Execution({target: config.sourceToken, value: 0, callData: abi.encodeCall(
                IERC20.transferFrom,
                (config.owner, ACCOUNT, amount)
            )});
    }

    /// @notice Creates a source-token approval for the supplied spender and allowance.
    function _approval(address spender, uint256 amount) internal view returns (Execution memory) {
        return
            Execution({target: config.sourceToken, value: 0, callData: abi.encodeCall(
                IERC20.approve,
                (spender, amount)
            )});
    }

    /// @notice Creates a fixed-shape ERC-2612 permit whose signature bytes are opaque to the policy.
    function _permit(address permitOwner, address spender, uint256 amount, uint256 deadline)
        internal
        view
        returns (Execution memory)
    {
        return
            Execution({target: config.sourceToken, value: 0, callData: abi.encodeCall(
                IERC20Permit.permit,
                (
                    permitOwner,
                    spender,
                    amount,
                    deadline,
                    uint8(27),
                    bytes32(uint256(1)),
                    bytes32(uint256(2))
                )
            )});
    }

    /// @notice Creates the minimal one-transfer operation shape.
    function _singleTransfer(uint256 amount) internal view returns (Execution[] memory executions) {
        executions = new Execution[](1);
        executions[0] = _transfer(amount);
    }

    /// @notice Signs the canonical execution mode and a complete fixed-route claim.
    function _envelope(Execution[] memory executions, HCAPermit2Lib.Claim memory claim)
        internal
        view
        returns (FundingEnvelope memory)
    {
        return _envelopeWithMode(executions, claim, HCAOperationHashLib.ERC7579_ERC1271_MODE);
    }

    /// @notice Signs a caller-selected operation mode, retaining production parsing on validation.
    function _envelopeWithMode(
        Execution[] memory executions,
        HCAPermit2Lib.Claim memory claim,
        bytes32 mode
    )
        internal
        view
        returns (FundingEnvelope memory)
    {
        return
            _seal(
                _encodeClaim(claim, _operationHash(mode, executions)),
                _packOperation(mode, executions)
            );
    }

    /// @notice Signs supplied claim and operation bytes without prevalidating their policies.
    function _seal(bytes memory claim, bytes memory operation)
        internal
        view
        returns (FundingEnvelope memory envelope)
    {
        envelope.digest = codec.digest(claim, block.chainid, PERMIT2);
        envelope.claim = claim;
        envelope.operation = operation;
        envelope.data = _joinEnvelope(
            config.permissionId,
            _ownerProof(ACCOUNT, config),
            _sessionSignature(ACCOUNT, envelope.digest),
            claim,
            operation
        );
    }

    /// @notice Joins the fixed source-mode prefix with supplied proof, signatures, and payload.
    function _joinEnvelope(
        bytes32 permissionId,
        bytes memory proof,
        bytes memory signature,
        bytes memory claim,
        bytes memory operation
    )
        internal
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(FUNDING_MODE, permissionId, proof, signature, claim, operation);
    }

    /// @notice Reconstructs the policy salt used by the production reusable owner authorization.
    function _authorizationSalt(HCAFundingSessionValidator.SessionConfig memory session)
        internal
        pure
        returns (bytes32)
    {
        return
            keccak256(
                abi.encode(
                    session.owner,
                    session.validUntil,
                    session.sourceToken,
                    session.destinationRecipient,
                    session.destinationToken,
                    session.destinationChainId,
                    session.maxSourceAmount,
                    session.maxDestinationAmount
                )
            );
    }

    /// @notice Produces a reusable owner proof containing exactly the current source chain.
    function _ownerProof(address account, HCAFundingSessionValidator.SessionConfig memory session)
        internal
        view
        returns (bytes memory)
    {
        return _ownerProofWithKey(account, session, OWNER_PRIVATE_KEY);
    }

    /// @notice Constructs the current-chain proof with an explicitly selected signing key.
    function _ownerProofWithKey(
        address account,
        HCAFundingSessionValidator.SessionConfig memory session,
        uint256 privateKey
    )
        internal
        view
        returns (bytes memory)
    {
        (, bytes32 sessionDigest) =
            HCASmartSessionLib.authorizationHashes(
                account,
                session.sessionKey,
                _authorizationSalt(session)
            );
        bytes32[] memory chainHashes = new bytes32[](1);
        chainHashes[0] = HCASmartSessionLib.chainSessionHash(uint64(block.chainid), sessionDigest);
        return
            abi.encodePacked(
                uint8(0),
                uint8(1),
                uint64(block.chainid),
                sessionDigest,
                _sign(privateKey, HCASmartSessionLib.multiChainDigest(chainHashes))
            );
    }

    /// @notice Signs the digest with its account binding and canonical direct recovery identifier.
    function _sessionSignature(address account, bytes32 digest)
        internal
        pure
        returns (bytes memory)
    {
        bytes32 accountBoundHash =
            MessageHashUtils.toEthSignedMessageHash(
                abi.encodePacked(bytes32(uint256(uint160(account))), digest)
            );
        return _sign(SESSION_PRIVATE_KEY, accountBoundHash);
    }

    /// @notice Generates a signature in the canonical domain accepted by the production recovery code.
    /// @dev Halmos models signing rather than executing secp256k1 and does not constrain s to low-s.
    ///      Its shared signature cache can omit the signing axioms on a sibling execution path.
    ///      The explicit assumptions below restate only the generated signature's canonical shape
    ///      and signer relationship; they assume no result from the validator or its policies.
    function _sign(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        vm.assume(v >= 27);
        vm.assume(v <= 28);
        vm.assume(uint256(r) > 0);
        vm.assume(uint256(r) < SECP256K1_ORDER);
        vm.assume(uint256(s) > 0);
        vm.assume(uint256(s) <= SECP256K1_ORDER / 2);
        vm.assume(ecrecover(digest, v, r, s) == vm.addr(privateKey));
        return abi.encodePacked(r, s, v);
    }

    /// @notice Invokes the unchanged validator as the selected account and reported signature caller.
    function _validate(address account, address sender, bytes32 digest, bytes memory data)
        internal
        returns (bool success, bytes memory result)
    {
        vm.prank(account);
        return
            address(validator).staticcall(
                abi.encodeCall(validator.isValidSignatureWithSender, (sender, digest, data))
            );
    }

    /// @notice Proves a signed operation reaches and successfully passes the entire public validator.
    function _assertValid(FundingEnvelope memory envelope) internal {
        (bool success, bytes memory result) =
            _validate(ACCOUNT, PERMIT2, envelope.digest, envelope.data);
        assert(success);
        assert(result.length == 32);
        assert(abi.decode(result, (bytes4)) == ERC1271_MAGICVALUE);
    }

    /// @notice Checks the exact failure of a complete signed envelope without discarding revert paths.
    function _assertError(FundingEnvelope memory envelope, bytes memory expectedError) internal {
        (bool success, bytes memory result) =
            _validate(ACCOUNT, PERMIT2, envelope.digest, envelope.data);
        _assertFailure(success, result, expectedError);
    }

    /// @notice Asserts a low-level failure and its complete revert payload.
    function _assertFailure(bool success, bytes memory result, bytes memory expectedError)
        internal
        pure
    {
        assert(!success);
        assert(result.length == expectedError.length);
        assert(keccak256(result) == keccak256(expectedError));
    }

    /// @notice Creates the production field-mismatch error payload.
    function _fieldError(uint8 field) internal pure returns (bytes memory) {
        return
            abi.encodeWithSelector(HCAFundingSessionValidator.ClaimFieldMismatch.selector, field);
    }

    /// @notice Replaces a fixed-width word inside an existing compact payload.
    function _writeWord(bytes memory data, uint256 offset, bytes32 value) internal pure {
        assert(offset + 32 <= data.length);
        assembly ("memory-safe") {
            mstore(add(add(data, 0x20), offset), value)
        }
    }
}
