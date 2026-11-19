// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Execution} from "nexus/types/DataTypes.sol";

import {HCAOwnerAndSessionValidator} from "~src/hca/HCAOwnerAndSessionValidator.sol";

import {OwnerSessionFixture} from "./owner/OwnerSessionFixture.sol";

/// @title HCA Owner Session Refund Authorization Proofs
/// @notice Checks owner-approved refund caps and EIP-712 binding through complete signed sessions.
/// @dev Every nonempty operation contains one permitted commit. Amount and exchange rate are
///      symbolic uint96 wire fields, overhead is a symbolic uint48, and authorization caps use the
///      same production widths. The claims concern validation, not actual paymaster reimbursement.
contract HCAOwnerSessionRefund is OwnerSessionFixture {
    /// @notice An authorized refund rate must be nonzero and no larger than the owner's cap.
    function check_exchangeRateCap(uint96 cap, uint96 rate) public {
        vm.assume(cap != 0);
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.maxRefundExchangeRate = cap;
        Envelope memory envelope = _envelope(proof, _commit(0), 0, _refund(rate, 1, 0));
        if (rate != 0 && rate <= cap)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
    }

    /// @notice An authorized token refund must be nonzero and no larger than the owner's amount cap.
    function check_amountCap(uint96 cap, uint96 amount) public {
        vm.assume(cap != 0);
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.maxRefundAmount = cap;
        Envelope memory envelope = _envelope(proof, _commit(0), 0, _refund(1, amount, 0));
        if (amount != 0 && amount <= cap)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
    }

    /// @notice Gas overhead may equal the owner's cap, including a zero cap, but cannot exceed it.
    function check_overheadCap(uint48 cap, uint48 overhead) public {
        HCAOwnerAndSessionValidator.SessionEnableProof memory proof = _proof();
        proof.maxRefundGasOverhead = cap;
        Envelope memory envelope = _envelope(proof, _commit(0), 0, _refund(1, 1, overhead));
        if (overhead <= cap)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
    }

    /// @notice A nonzero refund may use only the exact token authorized by the owner.
    function check_refundTokenBinding(address token) public {
        HCAOwnerAndSessionValidator.GasRefund memory refund = _refund(1, 1, 0);
        refund.token = token;
        Envelope memory envelope = _envelope(_proof(), _commit(0), 0, refund);
        if (token == PAYMENT_TOKEN)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
    }

    /// @notice A zero token means no refund only when rate, amount, and overhead are all zero.
    function check_noRefundCanonicalFields(uint96 rate, uint96 amount, uint48 overhead) public {
        HCAOwnerAndSessionValidator.GasRefund memory refund = _refund(rate, amount, overhead);
        refund.token = address(0);
        Envelope memory envelope = _envelope(_proof(), _commit(0), 0, refund);
        if (rate == 0 && amount == 0 && overhead == 0)
            _accept(envelope);
        else
            _reject(envelope, HCAOwnerAndSessionValidator.GasRefundNotAllowed.selector);
    }

    /// @notice The signed intent binds the complete exchange-rate field within otherwise valid caps.
    function check_signedExchangeRateBinding(uint96 original, uint96 changed) public {
        vm.assume(original != 0 && changed != 0 && original != changed);
        _rejectChangedRefund(_refund(original, 1, 0), _refund(changed, 1, 0), 0);
    }

    /// @notice The signed intent binds the amount carried in the high part of the refund overhead word.
    function check_signedAmountBinding(uint96 original, uint96 changed) public {
        vm.assume(original != 0 && changed != 0 && original != changed);
        _rejectChangedRefund(_refund(1, original, 0), _refund(1, changed, 0), 0);
    }

    /// @notice The signed intent binds the gas overhead carried in the low part of the refund word.
    function check_signedOverheadBinding(uint48 original, uint48 changed) public {
        vm.assume(original != changed);
        _rejectChangedRefund(_refund(1, 1, original), _refund(1, 1, changed), 0);
    }

    /// @notice A signed no-refund intent cannot be converted into a paid refund within the owner's caps.
    /// @dev Explicitly evaluates the precomputed no-refund hash so Halmos records its zero-field preimage.
    ///      The asserted constant equality is a checked hash definition, not a hash-separation assumption.
    function check_noRefundCannotBecomeRefund(uint96 amount, bytes32 commitment) public {
        vm.assume(amount != 0);
        assert(codec.refundStructHash(_noRefund()) == codec.noRefundHash());
        _rejectChangedRefund(_noRefund(), _refund(1, amount, 0), commitment);
    }

    /// @notice Even a correctly signed no-refund session must contain an actual permitted action.
    function check_emptyOperationRejected() public {
        _reject(
            _envelope(_proof(), new Execution[](0), 0, _noRefund()),
            HCAOwnerAndSessionValidator.PolicyRuleFailed.selector
        );
    }

    /// @dev Independently packs the production amount and overhead fields into their EIP-712 word.
    function _refund(uint96 rate, uint96 amount, uint48 overhead)
        private
        pure
        returns (HCAOwnerAndSessionValidator.GasRefund memory)
    {
        return
            HCAOwnerAndSessionValidator.GasRefund(
                PAYMENT_TOKEN,
                rate,
                (uint256(amount) << 128) | overhead
            );
    }

    /// @dev Presents changed refund calldata under the original externally supplied intent hash.
    function _rejectChangedRefund(
        HCAOwnerAndSessionValidator.GasRefund memory original,
        HCAOwnerAndSessionValidator.GasRefund memory changed,
        bytes32 commitment
    )
        private
    {
        Envelope memory originalEnvelope = _envelope(_proof(), _commit(commitment), 0, original);
        Envelope memory changedEnvelope = _envelope(_proof(), _commit(commitment), 0, changed);
        changedEnvelope.digest = originalEnvelope.digest;
        _reject(changedEnvelope, HCAOwnerAndSessionValidator.InvalidSessionData.selector);
    }
}
