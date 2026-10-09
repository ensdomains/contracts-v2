// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// solhint-disable func-name-mixedcase

import {HCAFundingFixture, HCAFundingClaimRouter} from "./funding/HCAFundingFixture.sol";

import {HCAFundingSessionValidator} from "~src/hca/HCAFundingSessionValidator.sol";
import {HCAPermit2Lib} from "~src/hca/libraries/HCAPermit2Lib.sol";
import {HCASmartSessionLib} from "~src/hca/libraries/HCASmartSessionLib.sol";

/// @notice Checks the production funding claim policy over complete, cryptographically signed envelopes.
/// @dev Each operation contains one transfer, each authorization selects one chain, and each claim
///      contains one source/output token except the explicit count check. Nonces span all uint256
///      values. Successful calls are asserted explicitly; invalid claims must reach their specific
///      production policy error. The claim codec constructs digests but supplies no policy decisions.
/// @custom:halmos --loop 4
contract HCAFundingClaims is HCAFundingFixture {
    /// @notice Any positive symbolic installed caps admit positive amounts within their respective limits.
    function check_SymbolicSessionCaps(
        uint96 sourceCap,
        uint96 destinationCap,
        uint96 sourceAmount,
        uint96 destinationAmount
    )
        public
    {
        vm.assume(sourceAmount > 0 && sourceAmount <= sourceCap);
        vm.assume(destinationAmount > 0 && destinationAmount <= destinationCap);
        _configureCaps(sourceCap, destinationCap);
        HCAPermit2Lib.Claim memory claim = _claim(sourceAmount, 0);
        claim.amountOut = destinationAmount;
        _assertValid(_envelope(_singleTransfer(sourceAmount), claim));
    }

    /// @notice An amount above any positive symbolic installed source cap fails the source policy.
    function check_SymbolicSourceCapExcessRejected(uint96 sourceCap, uint256 amount) public {
        vm.assume(sourceCap > 0);
        vm.assume(amount > sourceCap);
        _configureCaps(sourceCap, DESTINATION_CAP);
        _assertError(_envelope(_singleTransfer(amount), _claim(amount, 0)), _fieldError(4));
    }

    /// @notice An amount above any positive symbolic installed destination cap fails the output policy.
    function check_SymbolicDestinationCapExcessRejected(uint96 destinationCap, uint256 amount)
        public
    {
        vm.assume(destinationCap > 0);
        vm.assume(amount > destinationCap);
        _configureCaps(SOURCE_CAP, destinationCap);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.amountOut = amount;
        _assertError(_envelope(_singleTransfer(1), claim), _fieldError(8));
    }

    /// @notice Arbitrary live installed expiries accept claim deadlines and fills inside their current window.
    function check_SymbolicSessionTimeWindow(
        uint48 expiry,
        uint48 timestamp,
        uint48 deadline,
        uint48 fillExpiry
    )
        public
    {
        vm.assume(expiry > START_TIME);
        vm.assume(timestamp >= START_TIME && timestamp <= expiry);
        vm.assume(deadline >= timestamp && deadline <= expiry);
        vm.assume(fillExpiry >= timestamp && fillExpiry <= expiry);
        HCAFundingSessionValidator.SessionConfig memory replacement = config;
        replacement.validUntil = expiry;
        (replacement.permissionId, ) = HCASmartSessionLib.authorizationHashes(
            ACCOUNT,
            sessionKey,
            _authorizationSalt(replacement)
        );
        _replaceConfig(replacement);
        vm.warp(timestamp);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.deadline = deadline;
        claim.fillExpiry = fillExpiry;
        _assertValid(_envelope(_singleTransfer(1), claim));
    }

    /// @notice Every nonce and in-cap positive source/output amount reaches successful validation.
    function check_SignedClaimForEveryNonce(uint256 nonce, uint96 amount, uint96 amountOut) public {
        vm.assume(amount > 0 && amount <= SOURCE_CAP);
        vm.assume(amountOut > 0 && amountOut <= DESTINATION_CAP);
        HCAPermit2Lib.Claim memory claim = _claim(amount, nonce);
        claim.amountOut = amountOut;
        _assertValid(_envelope(_singleTransfer(amount), claim));
    }

    /// @notice Deadline and fill expiry accept both inclusive boundaries of the live session window.
    function check_DeadlineAndFillExpiryBoundaries(uint48 deadline, uint48 fillExpiry) public {
        vm.assume(deadline >= START_TIME && deadline <= SESSION_EXPIRY);
        vm.assume(fillExpiry >= START_TIME && fillExpiry <= SESSION_EXPIRY);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.deadline = deadline;
        claim.fillExpiry = fillExpiry;
        _assertValid(_envelope(_singleTransfer(1), claim));
    }

    /// @notice Any expired deadline or deadline beyond the installed expiry is rejected.
    function check_DeadlineOutsideSessionRejected(uint256 deadline) public {
        vm.assume(deadline < START_TIME || deadline > SESSION_EXPIRY);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.deadline = deadline;
        _assertError(_envelope(_singleTransfer(1), claim), _fieldError(2));
    }

    /// @notice Any expired fill window or fill expiry beyond the installed expiry is rejected.
    function check_FillExpiryOutsideSessionRejected(uint256 fillExpiry) public {
        vm.assume(fillExpiry < START_TIME || fillExpiry > SESSION_EXPIRY);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.fillExpiry = fillExpiry;
        _assertError(_envelope(_singleTransfer(1), claim), _fieldError(6));
    }

    /// @notice Source amounts pass exactly when positive and within the signed source cap.
    function check_SourceAmountPolicy(uint256 amount) public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(amount), _claim(amount, 0));
        if (amount > 0 && amount <= SOURCE_CAP) {
            _assertValid(envelope);
        } else {
            _assertError(envelope, _fieldError(4));
        }
    }

    /// @notice Output amounts pass exactly when positive and within the signed destination cap.
    function check_OutputAmountPolicy(uint256 amount) public {
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.amountOut = amount;
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), claim);
        if (amount > 0 && amount <= DESTINATION_CAP) {
            _assertValid(envelope);
        } else {
            _assertError(envelope, _fieldError(8));
        }
    }

    /// @notice A signed claim cannot replace the installed source token.
    function check_SourceTokenBound(address token) public {
        vm.assume(token != SOURCE_TOKEN);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.sourceToken = token;
        _assertError(_envelope(_singleTransfer(1), claim), _fieldError(4));
    }

    /// @notice A signed claim cannot redirect the destination recipient.
    function check_DestinationRecipientBound(address recipient) public {
        vm.assume(recipient != RECIPIENT);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.recipient = recipient;
        _assertError(_envelope(_singleTransfer(1), claim), _fieldError(5));
    }

    /// @notice A signed claim cannot select another destination chain, including oversized chain IDs.
    function check_DestinationChainBound(uint256 chainId) public {
        vm.assume(chainId != DESTINATION_CHAIN);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.targetChainId = chainId;
        _assertError(_envelope(_singleTransfer(1), claim), _fieldError(6));
    }

    /// @notice A signed claim cannot replace the installed destination token.
    function check_DestinationTokenBound(address token) public {
        vm.assume(token != DESTINATION_TOKEN);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.tokenOut = token;
        _assertError(_envelope(_singleTransfer(1), claim), _fieldError(8));
    }

    /// @notice A claim spender must be the active adapter returned for the production route.
    function check_SpenderMustMatchCurrentRoute(address spender) public {
        vm.assume(spender != ADAPTER);
        HCAPermit2Lib.Claim memory claim = _claim(1, 0);
        claim.spender = spender;
        _assertError(_envelope(_singleTransfer(1), claim), _fieldError(1));
    }

    /// @notice Router rotation rejects the old adapter and accepts a newly signed claim for the new one.
    function check_RouterRotationChangesOnlyActiveSpender(address replacement) public {
        vm.assume(replacement != address(0) && replacement != ADAPTER);
        FundingEnvelope memory oldEnvelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _assertValid(oldEnvelope);
        bytes32 beforeConfig = _sessionHash(ACCOUNT);
        router.setAdapter(replacement);
        _assertError(oldEnvelope, _fieldError(1));
        _assertValid(_envelope(_singleTransfer(1), _claim(1, 1)));
        assert(_sessionHash(ACCOUNT) == beforeConfig);
    }

    /// @notice A route with no active adapter cannot authorize a claim.
    function check_MissingRouteFailsClosed() public {
        router.setAdapter(address(0));
        _assertError(_envelope(_singleTransfer(1), _claim(1, 0)), _fieldError(1));
    }

    /// @notice Router failure propagates instead of producing an ERC-1271 success value.
    function check_RouterFailureFailsClosed() public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        router.setFailure(true);
        _assertError(
            envelope,
            abi.encodeWithSelector(HCAFundingClaimRouter.RouterUnavailable.selector)
        );
    }

    /// @notice The compact claim accepts exactly one source token and one destination token.
    function check_SingleTokenCounts(uint8 sourceCount, uint8 outputCount) public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.data[CLAIM_OFFSET + 84] = bytes1(sourceCount);
        envelope.data[CLAIM_OFFSET + 233] = bytes1(outputCount);
        if (sourceCount != 1) {
            _assertError(envelope, _fieldError(3));
        } else if (outputCount != 1) {
            _assertError(envelope, _fieldError(7));
        } else {
            _assertValid(envelope);
        }
    }

    /// @notice Changing the nonce without updating the signed digest fails the digest check.
    function check_NonceCommittedByDigest(uint256 nonce, uint256 changedNonce) public {
        vm.assume(changedNonce != nonce);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, nonce));
        _writeWord(envelope.data, CLAIM_OFFSET + 20, bytes32(changedNonce));
        _assertError(envelope, _fieldError(9));
    }

    /// @notice The signed digest commits to destination operations even though their execution is external.
    function check_DestinationOperationsCommitted(bytes32 changedHash) public {
        vm.assume(changedHash != bytes32(0));
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _writeWord(envelope.data, CLAIM_OFFSET + 346, changedHash);
        _assertError(envelope, _fieldError(9));
    }

    /// @notice The signed digest commits to the qualifier field.
    function check_QualifierCommitted(bytes32 changedHash) public {
        vm.assume(changedHash != bytes32(0));
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        _writeWord(envelope.data, CLAIM_OFFSET + 378, changedHash);
        _assertError(envelope, _fieldError(9));
    }

    /// @notice The Permit2 digest binds the source chain independently of owner-proof chain selection.
    function check_SourceChainBoundByPermit2Domain(uint256 differentChain) public {
        vm.assume(differentChain != SOURCE_CHAIN);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.digest = codec.digest(envelope.claim, differentChain, PERMIT2);
        envelope.data = _joinEnvelope(
            config.permissionId,
            _ownerProof(ACCOUNT, config),
            _sessionSignature(ACCOUNT, envelope.digest),
            envelope.claim,
            envelope.operation
        );
        _assertError(envelope, _fieldError(9));
    }

    /// @notice The Permit2 digest binds the configured Permit2 contract address.
    function check_Permit2AddressBoundByDomain(address differentPermit2) public {
        vm.assume(differentPermit2 != PERMIT2);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        envelope.digest = codec.digest(envelope.claim, SOURCE_CHAIN, differentPermit2);
        envelope.data = _joinEnvelope(
            config.permissionId,
            _ownerProof(ACCOUNT, config),
            _sessionSignature(ACCOUNT, envelope.digest),
            envelope.claim,
            envelope.operation
        );
        _assertError(envelope, _fieldError(9));
    }

    /// @notice Validating an identical signed nonce twice is read-only and does not consume it locally.
    /// @dev Replay rejection is a Permit2 responsibility, not a capability of this view validator.
    function check_ValidationDoesNotConsumePermit2Nonce(uint256 nonce, uint96 amount) public {
        vm.assume(amount > 0 && amount <= SOURCE_CAP);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(amount), _claim(amount, nonce));
        bytes32 beforeConfig = _sessionHash(ACCOUNT);
        _assertValid(envelope);
        _assertValid(envelope);
        assert(_sessionHash(ACCOUNT) == beforeConfig);
        assert(!validator.isPermissionEnabled(ACCOUNT, config.permissionId));
    }

    /// @notice The source cap limits each claim independently rather than accumulating a session budget.
    /// @dev Both distinct nonces are signed; no claim is made about Permit2 execution or token balances.
    function check_SourceCapIsPerClaim(uint96 first, uint96 second) public {
        vm.assume(first > 0 && first <= SOURCE_CAP);
        vm.assume(second > 0 && second <= SOURCE_CAP);
        vm.assume(uint256(first) + second > SOURCE_CAP);
        _assertValid(_envelope(_singleTransfer(first), _claim(first, 0)));
        _assertValid(_envelope(_singleTransfer(second), _claim(second, 1)));
    }

    /// @notice Checks zero-deadline rejection with concrete Foundry secp256k1 signatures.
    function test_ConcreteZeroDeadline() public {
        check_DeadlineOutsideSessionRejected(0);
    }

    /// @notice Checks zero-fill-expiry rejection with concrete Foundry secp256k1 signatures.
    function test_ConcreteZeroFillExpiry() public {
        check_FillExpiryOutsideSessionRejected(0);
    }

    /// @notice Checks a high-bit adapter address and router rotation using concrete signatures.
    function test_ConcreteRouterRotation() public {
        check_RouterRotationChangesOnlyActiveSpender(address(uint160(1) << 159));
    }

    /// @notice Checks two individually capped claims whose aggregate exceeds the cap using concrete signatures.
    function test_ConcreteIndependentClaimCaps() public {
        check_SourceCapIsPerClaim(uint96(1 << 19), uint96(1 << 19));
    }

    /// @notice Installs a freshly authorized capability containing caller-selected positive amount caps.
    function _configureCaps(uint96 sourceCap, uint96 destinationCap) internal {
        HCAFundingSessionValidator.SessionConfig memory replacement = config;
        replacement.maxSourceAmount = sourceCap;
        replacement.maxDestinationAmount = destinationCap;
        (replacement.permissionId, ) = HCASmartSessionLib.authorizationHashes(
            ACCOUNT,
            sessionKey,
            _authorizationSalt(replacement)
        );
        _replaceConfig(replacement);
    }
}
