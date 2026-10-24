// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Execution} from "nexus/types/DataTypes.sol";

import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";
import {HCAOperationHashLib} from "~src/hca/libraries/HCAOperationHashLib.sol";
import {HCAPermit2Lib} from "~src/hca/libraries/HCAPermit2Lib.sol";
import {IETHRegistrar} from "~src/registrar/interfaces/IETHRegistrar.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";

import {OwnerSessionPermit2Fixture} from "./owner/OwnerSessionPermit2Fixture.sol";

/// @title HCA Owner Session Permit2 Destination Proofs
/// @notice Verifies destination claims, operation binding, and registration payment-token policy.
/// @dev Complete signed envelopes are checked through the unmodified production validator. Claims
///      contain exactly one source token and one destination token; operations contain one or two
///      actions with fixed-word names and commitments. Expiry tests use uint48 timestamps so the
///      owner's uint48 session expiry remains live. No claim is made about origin funding, Permit2
///      nonce consumption, bridge execution, or cross-chain liveness.
contract HCAOwnerSessionPermit2 is OwnerSessionPermit2Fixture {
    /// @notice A live claim to this account with a nonzero source chain and output amount is admitted.
    function check_validPermit2Commit(
        uint256 sourceChain,
        uint256 amount,
        uint256 nonce,
        bytes32 commitment
    )
        public
    {
        vm.assume(sourceChain != 0 && amount != 0);
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        claim.amountOut = amount;
        _accept(_permitEnvelope(claim, _commit(commitment), sourceChain));
    }

    /// @notice The destination recipient must be exactly the account requesting validation.
    function check_recipientBinding(address recipient, uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        claim.recipient = recipient;
        Envelope memory envelope = _permitEnvelope(claim, _commit(0), 1);
        if (recipient == address(account))
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A destination claim is admitted only on its exact target chain.
    function check_targetChainBinding(uint64 currentChain, uint256 targetChain, uint256 nonce)
        public
    {
        vm.chainId(currentChain);
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        claim.targetChainId = targetChain;
        Envelope memory envelope = _permitEnvelope(claim, _commit(0), 1);
        if (targetChain == block.chainid)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A signed claim's deadline is inclusive and expired claims fail closed.
    function check_deadlineBoundary(uint48 timestamp, uint256 deadline) public {
        vm.warp(timestamp);
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.deadline = deadline;
        Envelope memory envelope = _permitEnvelope(claim, _commit(0), 1);
        if (deadline >= timestamp)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A signed claim's fill expiry is inclusive and cannot precede validation time.
    function check_fillExpiryBoundary(uint48 timestamp, uint256 expiry) public {
        vm.warp(timestamp);
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.fillExpiry = expiry;
        Envelope memory envelope = _permitEnvelope(claim, _commit(0), 1);
        if (expiry >= timestamp)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A zero source chain is rejected even when both signatures authenticate its digest.
    function check_zeroSourceChain(uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        _reject(
            _permitEnvelope(claim, _commit(0), 0),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice A Permit2 claim must name a nonzero spender.
    function check_spenderNonzero(address spender, uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.spender = spender;
        claim.nonce = nonce;
        Envelope memory envelope = _permitEnvelope(claim, _commit(0), 1);
        if (spender != address(0))
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A destination output token must be nonzero even for a commit-only operation.
    function check_outputTokenNonzero(address token, uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.tokenOut = token;
        claim.nonce = nonce;
        Envelope memory envelope = _permitEnvelope(claim, _commit(0), 1);
        if (token != address(0))
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice A zero destination amount is rejected independently of the permitted commit policy.
    function check_outputAmountNonzero(uint256 amount, uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.amountOut = amount;
        claim.nonce = nonce;
        Envelope memory envelope = _permitEnvelope(claim, _commit(0), 1);
        if (amount != 0)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice This destination validator does not impose an additional restriction on signed origin assets.
    /// @dev Origin funding authorization belongs to the funding validator and is explicitly outside scope.
    function check_signedSourceAssetFields(address token, uint256 amount, uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.sourceToken = token;
        claim.sourceAmount = amount;
        claim.nonce = nonce;
        _accept(_permitEnvelope(claim, _commit(0), 1));
    }

    /// @notice Both compact token-list counts must be exactly one.
    function check_claimTokenCounts(uint8 count, bool sourceCount, uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        Execution[] memory executions = _commit(0);
        bytes32 operationHash = _operationHash(HCAOperationHashLib.ERC7579_ERC1271_MODE, executions);
        bytes memory claimData = _claimData(claim, operationHash);
        claimData[sourceCount ? 84 : 233] = bytes1(count);
        Envelope memory envelope;
        envelope.digest = _permitDigest(claim, 1, operationHash);
        envelope.data = _permitWire(
            claimData,
            1,
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, executions),
            envelope.digest
        );
        if (count == 1)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice The signed destination-operation hash must describe the exact submitted operation.
    function check_destinationOperationBinding(bytes32 signedCommitment, bytes32 changedCommitment)
        public
    {
        vm.assume(signedCommitment != changedCommitment);
        HCAPermit2Lib.Claim memory claim = _claim();
        bytes32 operationHash =
            _operationHash(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(signedCommitment));
        Envelope memory envelope;
        envelope.digest = _permitDigest(claim, 1, operationHash);
        envelope.data = _permitWire(
            _claimData(claim, operationHash),
            1,
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, _commit(changedCommitment)),
            envelope.digest
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice A source-chain domain cannot be substituted under an existing authenticated Permit2 digest.
    function check_sourceChainDomainBinding(uint256 signedChain, uint256 changedChain, uint256 nonce)
        public
    {
        vm.assume(signedChain != 0 && changedChain != 0 && signedChain != changedChain);
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        Execution[] memory executions = _commit(0);
        bytes32 operationHash = _operationHash(HCAOperationHashLib.ERC7579_ERC1271_MODE, executions);
        Envelope memory envelope;
        envelope.digest = _permitDigest(claim, signedChain, operationHash);
        envelope.data = _permitWire(
            _claimData(claim, operationHash),
            changedChain,
            _encode(HCAOperationHashLib.ERC7579_ERC1271_MODE, executions),
            envelope.digest
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }

    /// @notice Emissary-only execution mode cannot authorize this ERC-1271 Permit2 destination path.
    function check_permit2RequiresERC1271Mode(uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        Execution[] memory executions = _commit(0);
        bytes32 mode = HCAOperationHashLib.ERC7579_EMISSARY_EXECUTION_MODE;
        bytes32 operationHash = _operationHash(mode, executions);
        Envelope memory envelope;
        envelope.digest = _permitDigest(claim, 1, operationHash);
        envelope.data = _permitWire(
            _claimData(claim, operationHash),
            1,
            _encode(mode, executions),
            envelope.digest
        );
        _reject(envelope, HCAOwnerAndSessionValidator.InvalidOperationEncoding.selector);
    }

    /// @notice A too-short destination operation fails before policy execution.
    function check_shortOperationRejected(uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        Envelope memory envelope;
        envelope.digest = _permitDigest(claim, 1, bytes32(0));
        envelope.data = _permitWire(_claimData(claim, bytes32(0)), 1, hex"020100", envelope.digest);
        _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice Registration requires the claim's output token to be supported by its registrar oracle.
    function check_registrationOutputTokenSupport(address outputToken, bool supported, uint256 nonce)
        public
    {
        vm.assume(outputToken != address(0));
        oracle.configure(outputToken, supported, false);
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.tokenOut = outputToken;
        claim.nonce = nonce;
        Envelope memory envelope =
            _permitEnvelope(claim, _one(address(registrar), _registration()), 1);
        if (supported)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @notice Oracle failure cannot authorize a registration output token.
    function check_registrationOracleFailure(uint256 nonce) public {
        oracle.configure(PAYMENT_TOKEN, true, true);
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        _reject(
            _permitEnvelope(claim, _one(address(registrar), _registration()), 1),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @notice Two registrations may share a registrar but cannot mix independently authorized registrars.
    function check_registrationBatchUsesOneRegistrar(bool sameRegistrar, uint256 nonce) public {
        HCAPermit2Lib.Claim memory claim = _claim();
        claim.nonce = nonce;
        Execution[] memory executions = new Execution[](2);
        executions[0] = Execution(address(registrar), 0, _registration());
        executions[1] = Execution(
            sameRegistrar ? address(registrar) : address(secondRegistrar),
            0,
            _registration()
        );
        Envelope memory envelope = _permitEnvelope(claim, executions, 1);
        if (sameRegistrar)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.PolicyRuleFailed.selector);
    }

    /// @dev Builds a policy-valid registration; registrar execution and name availability are unmodeled.
    function _registration() private view returns (bytes memory) {
        return
            abi.encodeCall(
                IETHRegistrar.register,
                (
                    "name",
                    owner,
                    bytes32(0),
                    IRegistry(address(0)),
                    address(resolver),
                    uint64(0),
                    IERC20(PAYMENT_TOKEN),
                    bytes32(0)
                )
            );
    }
}
