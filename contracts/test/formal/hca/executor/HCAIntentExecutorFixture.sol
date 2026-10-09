// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {Execution} from "nexus/types/DataTypes.sol";

import {StandaloneHCAFactory} from "~src/hca/StandaloneHCAFactory.sol";
import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";
import {IAddressSet} from "~src/utils/interfaces/IAddressSet.sol";
import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {HCAOperationHashLib} from "~src/hca/libraries/HCAOperationHashLib.sol";
import {HCASmartSessionLib} from "~src/hca/libraries/HCASmartSessionLib.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";

import {OwnerSessionWireCodec} from "../owner/OwnerSessionFixture.sol";

import {DeployedIntentExecutor} from "./DeployedIntentExecutor.sol";
import {IDeployedIntentExecutor} from "./IDeployedIntentExecutor.sol";

/// @title Intent Integration Registry Boundary
/// @notice Supplies registrar-role responses to the production session policy.
/// @dev ENS governance transitions are outside the executor integration claim.
contract HCAIntentRegistryBoundary {
    mapping(address candidate => bool authorized) internal _authorized;

    /// @notice Configures an independent registrar-role response.
    function setAuthorized(address candidate, bool authorized) external {
        _authorized[candidate] = authorized;
    }

    /// @notice Answers the registrar-role query performed by the production validator.
    function hasRootRoles(uint256 roles, address candidate) external view returns (bool) {
        return roles == RegistryRolesLib.ROLE_REGISTRAR && _authorized[candidate];
    }
}


/// @title Intent Integration Commit Target
/// @notice Records real calls, with an explicit failure switch for atomicity proofs.
/// @dev Models the registrar commit interface, not ENS commitment economics or registration.
contract HCAIntentCommitTarget {
    /// @notice Reports a deliberate target failure used by rollback proofs.
    error TargetRejected();

    bytes32 public firstCommitment;
    bytes32 public lastCommitment;
    address public lastCaller;
    uint256 public calls;
    bool public rejects;
    uint256 public rejectAtCall;
    IDeployedIntentExecutor public callbackExecutor;
    address public callbackAccount;
    uint256 public callbackNonce;
    bool public callbackAttempted;
    bool public callbackSucceeded;
    bool public callbackNonceWasConsumed;
    bytes4 public callbackError;
    uint256 public callbackReturnLength;

    /// @notice Controls whether subsequent commit calls revert.
    function setRejects(bool value) external {
        rejects = value;
    }

    /// @notice Selects a call index that deliberately reverts, with zero disabling the check.
    function setRejectAtCall(uint256 index) external {
        rejectAtCall = index;
    }

    /// @notice Enables one same-nonce callback attempt from the actual execution target.
    function configureCallback(IDeployedIntentExecutor executor, address account, uint256 nonce)
        external
    {
        callbackExecutor = executor;
        callbackAccount = account;
        callbackNonce = nonce;
    }

    /// @notice Records the commitment and actual EVM caller, or deliberately reverts.
    function commit(bytes32 commitment) external {
        if (rejects || calls + 1 == rejectAtCall)
            revert TargetRejected();
        if (calls == 0)
            firstCommitment = commitment;
        lastCommitment = commitment;
        lastCaller = msg.sender;
        ++calls;
        if (address(callbackExecutor) != address(0))
            _attemptCallback();
    }

    /// @notice Submits a correctly shaped unsigned intent whose nonce is already in use by its outer call.
    function _attemptCallback() internal {
        callbackAttempted = true;
        callbackNonceWasConsumed = callbackExecutor.isStandaloneIntentNonceConsumed(
            callbackNonce,
            callbackAccount
        );
        Execution[] memory empty = new Execution[](0);
        IDeployedIntentExecutor.SingleChainOps memory inner =
            IDeployedIntentExecutor.SingleChainOps({account: callbackAccount, nonce: callbackNonce, ops: IDeployedIntentExecutor.Operation(
                abi.encodePacked(bytes2(HCAOperationHashLib.ERC7579_ERC1271_MODE), abi.encode(empty))
            ), signature: ""});
        (bool success, bytes memory data) =
            address(callbackExecutor).call(
                abi.encodeCall(callbackExecutor.executeSinglechainOps, (inner))
            );
        // Observations are recorded only after the callback returns to this test target.
        // solgrid-disable-next-line security/reentrancy
        callbackSucceeded = success;
        // solgrid-disable-next-line security/reentrancy
        callbackError = bytes4(data);
        // solgrid-disable-next-line security/reentrancy
        callbackReturnLength = data.length;
    }
}


/// @title Real IntentExecutor and Certified HCA Fixture
/// @notice Calls pinned deployed executor bytecode through its real proxy, real validator, and certified HCA.
/// @dev Both HCA factories, both proxy layers, account, and validator execute production code.
///      Registrar-role responses and the commit target are explicit external boundaries.
///      The standalone ERC1271 route is covered; Compact, router, and emissary routes are not.
///      Proxy control state is pinned, with no action by the upstream upgrade authority.
///      Account nonce state begins unused; signatures inherit Halmos's cryptographic model.
abstract contract HCAIntentExecutorFixture is Test {
    uint256 internal constant OWNER_KEY = 0xA11CE;
    uint256 internal constant SESSION_KEY = 0x5E5510;
    uint256 internal constant WRONG_KEY = 0xBAD;
    address internal constant ENTRY_POINT = address(0x4337);
    address internal constant REFUND_TOKEN = address(0xC011);
    address internal constant PAYMASTER = 0x1d7df6Ddc7328Ac827EB4D7f171C60AFB7f9A599;

    IDeployedIntentExecutor internal executor;
    HCAOwnerAndSessionValidator internal validator;
    OwnerSessionWireCodec internal codec;
    VerifiableFactory internal verifiableFactory;
    StandaloneHCAFactory internal accountFactory;
    StandaloneSingleOwnerHCA internal implementation;
    StandaloneSingleOwnerHCA internal account;
    HCAIntentRegistryBoundary internal registry;
    HCAIntentCommitTarget internal firstTarget;
    HCAIntentCommitTarget internal secondTarget;
    address internal owner;
    address internal sessionKey;
    bool internal sepolia;

    /// @notice Deploys the production HCA stack against one pinned network's executor runtime.
    function _setUp(bool useSepolia) internal {
        sepolia = useSepolia;
        executor = IDeployedIntentExecutor(DeployedIntentExecutor.install(useSepolia));
        owner = vm.addr(OWNER_KEY);
        sessionKey = vm.addr(SESSION_KEY);
        vm.assume(owner != address(0) && sessionKey != address(0));
        vm.assume(owner != sessionKey);
        vm.assume(vm.addr(WRONG_KEY) != owner && vm.addr(WRONG_KEY) != sessionKey);
        registry = new HCAIntentRegistryBoundary();
        firstTarget = new HCAIntentCommitTarget();
        secondTarget = new HCAIntentCommitTarget();
        registry.setAuthorized(address(firstTarget), true);
        registry.setAuthorized(address(secondTarget), true);
        verifiableFactory = new VerifiableFactory();
        accountFactory = new StandaloneHCAFactory(verifiableFactory, address(this));
        validator = new HCAOwnerAndSessionValidator(
            address(0xDEFA),
            address(0xBEEF),
            address(0xFACE),
            address(registry),
            address(verifiableFactory),
            address(executor),
            PAYMASTER
        );
        implementation = new StandaloneSingleOwnerHCA(
            ENTRY_POINT,
            address(validator),
            address(executor),
            "",
            IAddressSet(address(0)),
            IAddressSet(address(0)),
            accountFactory
        );
        accountFactory.setImplementationApproval(address(implementation), true);
        account = _newAccount(0);
        codec = new OwnerSessionWireCodec(address(verifiableFactory));
        assert(
            codec.refundStructHash(HCAOwnerAndSessionValidator.GasRefund(address(0), 0, 0)) ==
            codec.noRefundHash()
        );
    }

    /// @notice Deploys a new certified HCA for the same owner using the production factories.
    function _newAccount(uint256 salt) internal returns (StandaloneSingleOwnerHCA) {
        return
            StandaloneSingleOwnerHCA(
                payable(accountFactory.deploy(owner, address(implementation), salt))
            );
    }

    /// @notice Builds a reusable owner-authorized session with finite refund permission bounds.
    function _proof(StandaloneSingleOwnerHCA selected)
        internal
        view
        returns (HCAOwnerAndSessionValidator.SessionEnableProof memory proof)
    {
        proof.sessionKey = sessionKey;
        proof.validUntil = type(uint48).max;
        (, proof.sessionNonce) = selected.ownerAndSessionNonce();
        proof.resolver = address(firstTarget);
        proof.refundToken = REFUND_TOKEN;
        proof.maxRefundExchangeRate = 1;
        proof.maxRefundGasOverhead = 1;
        proof.maxRefundAmount = 1;
    }

    /// @notice Restates the signing oracle's canonical range and recovery guarantee on every path.
    function _sign(uint256 key, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, digest);
        vm.assume(v == 27 || v == 28);
        vm.assume(uint256(r) > 0 && uint256(r) < SECP256K1_ORDER);
        vm.assume(uint256(s) > 0 && uint256(s) <= SECP256K1_ORDER / 2);
        vm.assume(ecrecover(digest, v, r, s) == vm.addr(key));
        return abi.encodePacked(r, s, v);
    }

    /// @notice Builds the operation hash independently from the compact policy encoding.
    function _operationHash(Execution[] memory executions) internal pure returns (bytes32) {
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
                    HCAOperationHashLib.ERC7579_ERC1271_MODE,
                    keccak256(abi.encodePacked(hashes))
                )
            );
    }

    /// @notice Encodes the operation copy consumed by the HCA session validator.
    function _compact(Execution[] memory executions) internal pure returns (bytes memory data) {
        data = abi.encodePacked(
            bytes2(HCAOperationHashLib.ERC7579_ERC1271_MODE),
            uint8(executions.length)
        );
        for (uint256 i; i < executions.length; ++i) {
            assert(executions[i].value == 0);
            data = bytes.concat(
                data,
                abi.encodePacked(
                    executions[i].target,
                    uint24(executions[i].callData.length),
                    executions[i].callData
                )
            );
        }
    }

    /// @notice Produces the no-refund, chain-bound standalone digest.
    function _digest(address selected, uint256 nonce, Execution[] memory executions)
        internal
        view
        returns (bytes32)
    {
        return
            codec.intentDigest(
                selected,
                nonce,
                _operationHash(executions),
                HCAOwnerAndSessionValidator.GasRefund(address(0), 0, 0),
                block.chainid,
                address(executor)
            );
    }

    /// @notice Encodes a one-chain owner authorization for the supplied account and session fields.
    function _authorization(
        address selected,
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof
    )
        internal
        view
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
            selected,
            proof.sessionKey,
            salt
        );
        bytes32[] memory chains = new bytes32[](1);
        chains[0] = HCASmartSessionLib.chainSessionHash(uint64(block.chainid), sessionDigest);
        packed = bytes.concat(
            abi.encodePacked(
                proof.sessionKey,
                proof.validUntil,
                proof.sessionNonce,
                proof.resolver,
                proof.refundToken
            ),
            abi.encodePacked(
                proof.maxRefundExchangeRate,
                proof.maxRefundGasOverhead,
                proof.maxRefundAmount,
                uint8(0),
                uint8(1)
            ),
            abi.encodePacked(uint64(block.chainid), sessionDigest),
            _sign(OWNER_KEY, HCASmartSessionLib.multiChainDigest(chains))
        );
    }

    /// @notice Encodes the executor's ABI batch and the HCA's independently validated compact copy.
    function _sessionIntent(
        StandaloneSingleOwnerHCA selected,
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof,
        Execution[] memory executions,
        uint256 nonce,
        uint256 signingKey
    )
        internal
        view
        returns (IDeployedIntentExecutor.SingleChainOps memory intent)
    {
        intent = _unsignedIntent(selected, executions, nonce);
        (bytes32 permissionId, bytes memory packed) = _authorization(address(selected), proof);
        intent.signature = bytes.concat(
            abi.encodePacked(address(0), codec.refundMode(), permissionId, packed, nonce),
            abi.encodePacked(address(0), uint96(0), uint96(0), uint48(0)),
            _compact(executions),
            _sign(signingKey, _digest(address(selected), nonce, executions))
        );
    }

    /// @notice Creates an owner signature through the same real ERC1271 route.
    function _ownerIntent(
        StandaloneSingleOwnerHCA selected,
        Execution[] memory executions,
        uint256 nonce
    )
        internal
        view
        returns (IDeployedIntentExecutor.SingleChainOps memory intent)
    {
        intent = _unsignedIntent(selected, executions, nonce);
        intent.signature = abi.encodePacked(
            address(0),
            _sign(OWNER_KEY, _digest(address(selected), nonce, executions))
        );
    }

    /// @notice Encodes the exact operation tuple expected by the deployed executor ABI.
    function _unsignedIntent(
        StandaloneSingleOwnerHCA selected,
        Execution[] memory executions,
        uint256 nonce
    )
        internal
        pure
        returns (IDeployedIntentExecutor.SingleChainOps memory intent)
    {
        intent.account = address(selected);
        intent.nonce = nonce;
        intent.ops.data = abi.encodePacked(
            bytes2(HCAOperationHashLib.ERC7579_ERC1271_MODE),
            abi.encode(executions)
        );
    }

    /// @notice Builds one concrete call shape with a symbolic commitment.
    function _commit(HCAIntentCommitTarget target, bytes32 commitment)
        internal
        pure
        returns (Execution[] memory executions)
    {
        executions = new Execution[](1);
        executions[0] = Execution(address(target), 0, abi.encodeCall(target.commit, (commitment)));
    }

    /// @notice Submits the intent to the real public entry point without impersonating the executor.
    function _submit(IDeployedIntentExecutor.SingleChainOps memory intent)
        internal
        returns (bool, bytes memory)
    {
        return address(executor).call(abi.encodeCall(executor.executeSinglechainOps, (intent)));
    }

    /// @notice Asserts unchanged certified ownership, HCA nonce, and pinned executor control state.
    function _assertState(StandaloneSingleOwnerHCA selected, uint96 nonce) internal view {
        (address reported, uint96 actualNonce) = selected.ownerAndSessionNonce();
        assert(reported == owner && actualNonce == nonce);
        assert(accountFactory.hcaOwners(address(selected)) == owner);
        assert(executor.implementation() == DeployedIntentExecutor.IMPLEMENTATION);
        assert(executor.owner() == DeployedIntentExecutor.PROXY_OWNER);
    }
}
