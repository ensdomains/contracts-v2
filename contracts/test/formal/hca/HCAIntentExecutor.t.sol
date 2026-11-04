// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {HCAIntentExecutorFixture} from "./executor/HCAIntentExecutorFixture.sol";
import {IDeployedIntentExecutor} from "./executor/IDeployedIntentExecutor.sol";
import {DeployedIntentExecutor} from "./executor/DeployedIntentExecutor.sol";

import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";

import {Execution} from "nexus/types/DataTypes.sol";

import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";

/// @title Pinned Real Executor Integration Properties
/// @notice Verifies execution through the deployed executor, production validator, and certified HCA.
/// @dev Each concrete suite selects one attested deployment. Calls have fixed finite shapes.
abstract contract HCAIntentExecutorProperties is HCAIntentExecutorFixture {
    /// @notice Both deployed code layers and the configured chain retain their captured identity.
    function check_deployedRuntimeIdentity() public view {
        assert(address(executor) == DeployedIntentExecutor.PROXY);
        assert(address(executor).codehash == DeployedIntentExecutor.PROXY_CODE_HASH);
        assert(
            DeployedIntentExecutor.IMPLEMENTATION.codehash ==
            (sepolia
                    ? DeployedIntentExecutor.SEPOLIA_CODE_HASH
                    : DeployedIntentExecutor.MAINNET_CODE_HASH)
        );
        assert(block.chainid == (sepolia ? 11155111 : 1));
        assert(executor.isInitialized(address(implementation)));
        assert(!executor.isInitialized(address(account)));
        _assertState(account, 0);
    }

    /// @notice A real owner-authorized session executes the commitment from the certified HCA.
    function check_validSessionExecutesAndConsumesNonce(
        bytes32 commitment,
        uint256 nonce,
        address relayer
    )
        public
    {
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(
                account,
                _proof(account),
                _commit(firstTarget, commitment),
                nonce,
                SESSION_KEY
            );
        vm.prank(relayer);
        (bool ok, ) = _submit(intent);
        assert(ok);
        assert(firstTarget.calls() == 1);
        assert(firstTarget.lastCaller() == address(account));
        assert(firstTarget.lastCommitment() == commitment);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice An owner signature follows the same real executor and HCA path.
    function check_ownerSignatureExecutes(bytes32 commitment, uint256 nonce) public {
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _ownerIntent(account, _commit(firstTarget, commitment), nonce);
        (bool ok, ) = _submit(intent);
        assert(ok);
        assert(firstTarget.calls() == 1 && firstTarget.lastCaller() == address(account));
        assert(firstTarget.lastCommitment() == commitment);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice Replaying a successful session intent cannot execute its target a second time.
    function check_replayRejectedWithoutStateChange(bytes32 commitment, uint256 nonce) public {
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(
                account,
                _proof(account),
                _commit(firstTarget, commitment),
                nonce,
                SESSION_KEY
            );
        (bool first, ) = _submit(intent);
        assert(first);
        (bool replay, ) = _submit(intent);
        assert(!replay);
        assert(firstTarget.calls() == 1 && firstTarget.lastCommitment() == commitment);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice A wrong session signer rolls the executor nonce back and permits a correctly signed retry.
    function check_invalidSessionSignatureRollsBackNonce(bytes32 commitment, uint256 nonce) public {
        Execution[] memory calls = _commit(firstTarget, commitment);
        IDeployedIntentExecutor.SingleChainOps memory invalid =
            _sessionIntent(account, _proof(account), calls, nonce, WRONG_KEY);
        (bool rejected, ) = _submit(invalid);
        assert(!rejected);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        assert(firstTarget.calls() == 0);
        IDeployedIntentExecutor.SingleChainOps memory valid =
            _sessionIntent(account, _proof(account), calls, nonce, SESSION_KEY);
        (bool accepted, ) = _submit(valid);
        assert(accepted);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        assert(firstTarget.calls() == 1);
        _assertState(account, 0);
    }

    /// @notice A wrong owner signer cannot consume a nonce or execute a target.
    function check_invalidOwnerSignatureRollsBackNonce(bytes32 commitment, uint256 nonce) public {
        Execution[] memory calls = _commit(firstTarget, commitment);
        IDeployedIntentExecutor.SingleChainOps memory invalid =
            _unsignedIntent(account, calls, nonce);
        invalid.signature = abi.encodePacked(
            address(0),
            _sign(WRONG_KEY, _digest(address(account), nonce, calls))
        );
        (bool ok, ) = _submit(invalid);
        assert(!ok);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        assert(firstTarget.calls() == 0);
        _assertState(account, 0);
    }

    /// @notice Live registrar authorization determines execution, including nonce rollback on rejection.
    function check_policyAuthorizationControlsWholeExecution(
        bytes32 commitment,
        uint256 nonce,
        bool authorized
    )
        public
    {
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(
                account,
                _proof(account),
                _commit(firstTarget, commitment),
                nonce,
                SESSION_KEY
            );
        registry.setAuthorized(address(firstTarget), authorized);
        (bool ok, ) = _submit(intent);
        assert(ok == authorized);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)) == authorized);
        assert(firstTarget.calls() == (authorized ? 1 : 0));
        _assertState(account, 0);
    }

    /// @notice The expiry timestamp is inclusive, with rejected intents leaving replay state unused.
    function check_expiryBoundaryControlsWholeExecution(
        bytes32 commitment,
        uint256 nonce,
        uint48 expiry,
        bool expired
    )
        public
    {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof(account);
        proof.validUntil = expiry;
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(account, proof, _commit(firstTarget, commitment), nonce, SESSION_KEY);
        vm.warp(uint256(expiry) + (expired ? 1 : 0));
        (bool ok, ) = _submit(intent);
        assert(ok == !expired);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)) == !expired);
        assert(firstTarget.calls() == (expired ? 0 : 1));
        _assertState(account, 0);
    }

    /// @notice Revocation rejects a stale owner authorization even when its executor nonce is fresh.
    function check_revocationRejectsFreshIntentFromStaleSession(bytes32 commitment, uint256 nonce)
        public
    {
        HCAOwnerAndSessionValidator.SessionEnableProof memory stale = _proof(account);
        Execution[] memory calls = _commit(firstTarget, commitment);
        (bool first, ) = _submit(_sessionIntent(account, stale, calls, nonce, SESSION_KEY));
        assert(first);
        vm.prank(owner);
        account.revokeSessions();
        uint256 freshNonce = nonce ^ 1;
        (bool staleAccepted, ) =
            _submit(_sessionIntent(account, stale, calls, freshNonce, SESSION_KEY));
        assert(!staleAccepted);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        assert(!executor.isStandaloneIntentNonceConsumed(freshNonce, address(account)));
        assert(firstTarget.calls() == 1);
        _assertState(account, 1);
    }

    /// @notice A newly owner-authorized session succeeds after a real account revocation.
    function check_newAuthorizationSucceedsAfterRevocation(bytes32 commitment, uint256 nonce)
        public
    {
        vm.prank(owner);
        account.revokeSessions();
        (bool ok, ) =
            _submit(
                _sessionIntent(
                    account,
                    _proof(account),
                    _commit(firstTarget, commitment),
                    nonce,
                    SESSION_KEY
                )
            );
        assert(ok);
        assert(firstTarget.calls() == 1);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 1);
    }

    /// @notice The same executor nonce can be consumed independently by two real certified accounts.
    function check_nonceIsolationAcrossCertifiedAccounts(bytes32 commitment, uint256 nonce) public {
        StandaloneSingleOwnerHCA other = _newAccount(1);
        Execution[] memory calls = _commit(firstTarget, commitment);
        (bool first, ) =
            _submit(_sessionIntent(account, _proof(account), calls, nonce, SESSION_KEY));
        assert(first);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(other)));
        (bool second, ) = _submit(_sessionIntent(other, _proof(other), calls, nonce, SESSION_KEY));
        assert(second);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(other)));
        assert(firstTarget.calls() == 2 && firstTarget.lastCaller() == address(other));
        _assertState(account, 0);
        _assertState(other, 0);
    }

    /// @notice Distinct nonce keys remain independent within one account.
    function check_distinctNonceKeysRemainIndependent(
        bytes32 commitment,
        uint256 firstNonce,
        uint256 secondNonce
    )
        public
    {
        vm.assume(firstNonce != secondNonce);
        Execution[] memory calls = _commit(firstTarget, commitment);
        (bool first, ) =
            _submit(_sessionIntent(account, _proof(account), calls, firstNonce, SESSION_KEY));
        assert(first);
        assert(!executor.isStandaloneIntentNonceConsumed(secondNonce, address(account)));
        (bool second, ) =
            _submit(_sessionIntent(account, _proof(account), calls, secondNonce, SESSION_KEY));
        assert(second);
        assert(executor.isStandaloneIntentNonceConsumed(firstNonce, address(account)));
        assert(executor.isStandaloneIntentNonceConsumed(secondNonce, address(account)));
        assert(firstTarget.calls() == 2);
        _assertState(account, 0);
    }

    /// @notice Failure of a later target rolls back earlier target writes and the executor nonce; the intent can be retried.
    function check_atomicTargetFailureAndRetry(bytes32 first, bytes32 last, uint256 nonce) public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(firstTarget), 0, abi.encodeCall(firstTarget.commit, (first)));
        calls[1] = Execution(address(firstTarget), 0, abi.encodeCall(firstTarget.commit, (last)));
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(account, _proof(account), calls, nonce, SESSION_KEY);
        firstTarget.setRejectAtCall(2);
        (bool failed, ) = _submit(intent);
        assert(!failed);
        assert(firstTarget.calls() == 0 && secondTarget.calls() == 0);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
        firstTarget.setRejectAtCall(0);
        (bool retried, ) = _submit(intent);
        assert(retried);
        assert(firstTarget.calls() == 2 && secondTarget.calls() == 0);
        assert(firstTarget.firstCommitment() == first && firstTarget.lastCommitment() == last);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice An owner-signed batch updates every target; an aliased target observes the signed order.
    function check_batchAliasingAndOrder(bytes32 first, bytes32 last, uint256 nonce, bool sameTarget)
        public
    {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(firstTarget), 0, abi.encodeCall(firstTarget.commit, (first)));
        calls[1] = Execution(
            sameTarget ? address(firstTarget) : address(secondTarget),
            0,
            abi.encodeCall(firstTarget.commit, (last))
        );
        (bool ok, ) = _submit(_ownerIntent(account, calls, nonce));
        assert(ok);
        assert(firstTarget.calls() == (sameTarget ? 2 : 1));
        assert(secondTarget.calls() == (sameTarget ? 0 : 1));
        assert(firstTarget.lastCommitment() == (sameTarget ? last : first));
        if (!sameTarget)
            assert(secondTarget.lastCommitment() == last);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice A session cannot execute a batch containing two different authorized registrars.
    function check_distinctRegistrarSessionBatchRejected(bytes32 commitment, uint256 nonce) public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(
            address(firstTarget),
            0,
            abi.encodeCall(firstTarget.commit, (commitment))
        );
        calls[1] = Execution(
            address(secondTarget),
            0,
            abi.encodeCall(secondTarget.commit, (commitment))
        );
        (bool ok, ) = _submit(_sessionIntent(account, _proof(account), calls, nonce, SESSION_KEY));
        assert(!ok);
        assert(firstTarget.calls() == 0 && secondTarget.calls() == 0);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice Changing the executed calldata cannot bypass the independently signed HCA operation copy.
    function check_outerOperationMutationRejected(bytes32 commitment, uint256 nonce) public {
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(
                account,
                _proof(account),
                _commit(firstTarget, commitment),
                nonce,
                SESSION_KEY
            );
        intent.ops = _unsignedIntent(
            account,
            _commit(firstTarget, commitment ^ bytes32(uint256(1))),
            nonce
        ).ops;
        (bool ok, ) = _submit(intent);
        assert(!ok);
        assert(firstTarget.calls() == 0);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice Changing the executor nonce cannot reuse an envelope that commits to another nonce.
    function check_outerNonceMutationRejected(bytes32 commitment, uint256 nonce) public {
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(
                account,
                _proof(account),
                _commit(firstTarget, commitment),
                nonce,
                SESSION_KEY
            );
        intent.nonce = nonce ^ 1;
        (bool ok, ) = _submit(intent);
        assert(!ok);
        assert(firstTarget.calls() == 0);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        assert(!executor.isStandaloneIntentNonceConsumed(nonce ^ 1, address(account)));
        _assertState(account, 0);
    }

    /// @notice An owner authorization for one certified account cannot be transplanted to another.
    function check_outerAccountMutationRejected(bytes32 commitment, uint256 nonce) public {
        StandaloneSingleOwnerHCA other = _newAccount(1);
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(
                account,
                _proof(account),
                _commit(firstTarget, commitment),
                nonce,
                SESSION_KEY
            );
        intent.account = address(other);
        (bool ok, ) = _submit(intent);
        assert(!ok);
        assert(firstTarget.calls() == 0);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(other)));
        _assertState(account, 0);
        _assertState(other, 0);
    }

    /// @notice CHAINID mutation rejects an intent; restoring CHAINID permits it with the same loaded runtime.
    function check_chainBindingAndRejectedAttemptRollback(bytes32 commitment, uint256 nonce) public {
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(
                account,
                _proof(account),
                _commit(firstTarget, commitment),
                nonce,
                SESSION_KEY
            );
        uint256 originalChain = block.chainid;
        vm.chainId(sepolia ? 1 : 11155111);
        (bool wrongChain, ) = _submit(intent);
        assert(!wrongChain);
        assert(firstTarget.calls() == 0);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        vm.chainId(originalChain);
        (bool restored, ) = _submit(intent);
        assert(restored);
        assert(firstTarget.calls() == 1);
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice A no-refund authorization rejects an actual refund entry before any settlement dependency is reached.
    function check_unsignedRefundTermsRejected(bytes32 commitment, uint256 nonce, address recipient)
        public
    {
        IDeployedIntentExecutor.SingleChainOps memory intent =
            _sessionIntent(
                account,
                _proof(account),
                _commit(firstTarget, commitment),
                nonce,
                SESSION_KEY
            );
        IDeployedIntentExecutor.GasRefund memory refund =
            IDeployedIntentExecutor.GasRefund(REFUND_TOKEN, 1, 1);
        (bool ok, bytes memory data) =
            address(executor).call(
                abi.encodeCall(
                    executor.executeSinglechainOpsWithGasRefund_ERC20,
                    (intent, refund, recipient)
                )
            );
        assert(!ok);
        assert(data.length == 4 && bytes4(data) == IDeployedIntentExecutor.InvalidSignature.selector);
        assert(firstTarget.calls() == 0);
        assert(!executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice A same-nonce callback observes consumption and cannot replay while its outer intent succeeds.
    /// @dev The pinned nonce guard returns four zero bytes because its selector is stored right-aligned.
    ///      Distinct-nonce reentrancy and arbitrary callback programs are outside this property.
    function check_sameNonceCallbackRejected(bytes32 commitment, uint256 nonce) public {
        firstTarget.configureCallback(executor, address(account), nonce);
        (bool ok, ) =
            _submit(
                _sessionIntent(
                    account,
                    _proof(account),
                    _commit(firstTarget, commitment),
                    nonce,
                    SESSION_KEY
                )
            );
        assert(ok);
        assert(firstTarget.callbackAttempted());
        assert(firstTarget.callbackNonceWasConsumed());
        assert(!firstTarget.callbackSucceeded());
        assert(firstTarget.callbackReturnLength() == 4 && firstTarget.callbackError() == bytes4(0));
        assert(firstTarget.calls() == 1 && firstTarget.lastCommitment() == commitment);
        assert(firstTarget.lastCaller() == address(account));
        assert(executor.isStandaloneIntentNonceConsumed(nonce, address(account)));
        _assertState(account, 0);
    }

    /// @notice Confirms a concrete owner-authorized session and same-nonce callback rejection in the native EVM.
    function test_realSessionSuccessAndSameNonceCallback() public {
        check_sameNonceCallbackRejected(bytes32(uint256(0xCAFE)), 7);
    }

    /// @notice Confirms that a successfully executed signed intent cannot be replayed in the native EVM.
    function test_realSessionSuccessAndSequentialReplay() public {
        check_replayRejectedWithoutStateChange(bytes32(uint256(0xCAFE)), 7);
    }

    /// @notice Confirms concrete rollback and retry with real cryptography in the native EVM.
    function test_realAtomicFailureAndRetry() public {
        check_atomicTargetFailureAndRetry(bytes32(uint256(0x1111)), bytes32(uint256(0x2222)), 9);
    }
}


/// @notice Runs the integration properties against the pinned Ethereum mainnet deployment.
/// @custom:halmos --storage-layout generic
contract HCAIntentExecutorMainnetTest is HCAIntentExecutorProperties {
    /// @notice Installs mainnet runtime and the production HCA stack.
    function setUp() public {
        _setUp(false);
    }
}


/// @notice Runs the integration properties against the pinned Sepolia deployment.
/// @custom:halmos --storage-layout generic
contract HCAIntentExecutorSepoliaTest is HCAIntentExecutorProperties {
    /// @notice Installs Sepolia runtime and the production HCA stack.
    function setUp() public {
        _setUp(true);
    }
}
