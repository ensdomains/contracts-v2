// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// solhint-disable func-name-mixedcase

import {HCAFundingFixture} from "./funding/HCAFundingFixture.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {Execution} from "nexus/types/DataTypes.sol";

import {HCAFundingSessionValidator} from "~src/hca/HCAFundingSessionValidator.sol";
import {HCAOperationHashLib} from "~src/hca/libraries/HCAOperationHashLib.sol";

/// @notice Proves source-operation policy through the unchanged public signed-claim validator.
/// @dev Operations have independently selected fixed shapes containing at most three calls. The
///      fixture signs the claim and operation commitment; these checks do not assume policy success.
///      Approval/permit calls are inspected but not executed, so acceptance does not prove sufficient
///      token allowance, a valid token permit signature, or an executable ordering of token calls.
/// @custom:halmos --loop 4
contract HCAFundingOperations is HCAFundingFixture {
    /// @notice An approval covering the pull is accepted before or after the transfer.
    /// @dev The policy does not impose an ordering between approval and pulling the owner's tokens.
    function check_ApprovalOrdering(uint96 amount, uint256 allowance, bool approvalFirst) public {
        vm.assume(amount > 0 && amount <= SOURCE_CAP);
        vm.assume(allowance >= amount);
        Execution[] memory executions = new Execution[](2);
        executions[approvalFirst ? 0 : 1] = _approval(PERMIT2, allowance);
        executions[approvalFirst ? 1 : 0] = _transfer(amount);
        _assertValid(_envelope(executions, _claim(amount, 0)));
    }

    /// @notice An included approval below the total pull fails for either relative call ordering.
    function check_InsufficientApprovalRejected(uint96 amount, uint256 allowance, bool approvalFirst)
        public
    {
        vm.assume(amount > 0 && amount <= SOURCE_CAP);
        vm.assume(allowance < amount);
        Execution[] memory executions = new Execution[](2);
        executions[approvalFirst ? 0 : 1] = _approval(PERMIT2, allowance);
        executions[approvalFirst ? 1 : 0] = _transfer(amount);
        _assertFundingFailure(executions, amount);
    }

    /// @notice A permit, approval, and pull pass in forward or reverse order when policy fields fit.
    /// @dev The permit amount is independently capped; the validator does not require it to cover the
    ///      pull. Token execution may therefore fail for an accepted operation, including reversed order.
    function check_PermitApprovalPullOrdering(
        uint96 amount,
        uint96 permitAmount,
        uint256 allowance,
        uint48 deadline,
        bool reverseOrder
    )
        public
    {
        vm.assume(amount > 0 && amount <= SOURCE_CAP);
        vm.assume(permitAmount <= SOURCE_CAP);
        vm.assume(allowance >= amount);
        vm.assume(deadline >= START_TIME && deadline <= SESSION_EXPIRY);
        Execution[] memory executions = new Execution[](3);
        executions[reverseOrder ? 2 : 0] = _permit(owner, ACCOUNT, permitAmount, deadline);
        executions[1] = _approval(PERMIT2, allowance);
        executions[reverseOrder ? 0 : 2] = _transfer(amount);
        _assertValid(_envelope(executions, _claim(amount, 0)));
    }

    /// @notice Two pulls pass exactly when their sum is positive, capped, and equal to the claim.
    /// @dev Each pull spans uint96, so summing them in uint256 cannot overflow in this check.
    function check_AggregatePullMatchesClaim(uint96 first, uint96 second, uint96 claimed) public {
        vm.assume(claimed > 0 && claimed <= SOURCE_CAP);
        Execution[] memory executions = new Execution[](2);
        executions[0] = _transfer(first);
        executions[1] = _transfer(second);
        uint256 total = uint256(first) + second;
        FundingEnvelope memory envelope = _envelope(executions, _claim(claimed, 0));
        if (total > 0 && total <= SOURCE_CAP && total == claimed) {
            _assertValid(envelope);
        } else {
            _assertError(
                envelope,
                abi.encodeWithSelector(HCAFundingSessionValidator.FundingPolicyFailed.selector)
            );
        }
    }

    /// @notice An overflowing aggregate pull fails closed with Solidity's arithmetic panic.
    function check_AggregatePullOverflowFailsClosed(uint256 first, uint256 second) public {
        vm.assume(second > type(uint256).max - first);
        Execution[] memory executions = new Execution[](2);
        executions[0] = _transfer(first);
        executions[1] = _transfer(second);
        _assertError(
            _envelope(executions, _claim(1, 0)),
            abi.encodeWithSignature("Panic(uint256)", uint256(0x11))
        );
    }

    /// @notice A transfer cannot pull from an address other than the installed owner.
    function check_TransferOwnerBound(address from) public {
        vm.assume(from != owner);
        Execution[] memory executions = _singleTransfer(1);
        executions[0].callData = abi.encodeCall(IERC20.transferFrom, (from, ACCOUNT, uint256(1)));
        _assertFundingFailure(executions, 1);
    }

    /// @notice A transfer cannot send the source tokens to an address other than its source account.
    function check_TransferRecipientBound(address to) public {
        vm.assume(to != ACCOUNT);
        Execution[] memory executions = _singleTransfer(1);
        executions[0].callData = abi.encodeCall(IERC20.transferFrom, (owner, to, uint256(1)));
        _assertFundingFailure(executions, 1);
    }

    /// @notice Every funding execution must target the configured source token.
    function check_ExecutionTargetBound(address target) public {
        vm.assume(target != SOURCE_TOKEN);
        Execution[] memory executions = _singleTransfer(1);
        executions[0].target = target;
        _assertFundingFailure(executions, 1);
    }

    /// @notice A source-token approval cannot name any spender other than the configured Permit2.
    function check_ApprovalSpenderBound(address spender, uint256 allowance) public {
        vm.assume(spender != PERMIT2);
        Execution[] memory executions = new Execution[](2);
        executions[0] = _approval(spender, allowance);
        executions[1] = _transfer(1);
        _assertFundingFailure(executions, 1);
    }

    /// @notice Two individually valid approvals are rejected as a duplicate capability.
    function check_DuplicateApprovalsRejected(uint256 firstAllowance, uint256 secondAllowance)
        public
    {
        Execution[] memory executions = new Execution[](3);
        executions[0] = _approval(PERMIT2, firstAllowance);
        executions[1] = _transfer(1);
        executions[2] = _approval(PERMIT2, secondAllowance);
        _assertFundingFailure(executions, 1);
    }

    /// @notice Approval-only operations cannot fund a positive claim.
    function check_ApprovalWithoutPullRejected(uint256 allowance) public {
        Execution[] memory executions = new Execution[](1);
        executions[0] = _approval(PERMIT2, allowance);
        _assertFundingFailure(executions, 1);
    }

    /// @notice Two otherwise valid token permits are rejected even when separated by the pull.
    function check_DuplicatePermitsRejected(uint96 firstAmount, uint96 secondAmount) public {
        vm.assume(firstAmount <= SOURCE_CAP && secondAmount <= SOURCE_CAP);
        Execution[] memory executions = new Execution[](3);
        executions[0] = _permit(owner, ACCOUNT, firstAmount, SESSION_EXPIRY);
        executions[1] = _transfer(1);
        executions[2] = _permit(owner, ACCOUNT, secondAmount, SESSION_EXPIRY);
        _assertFundingFailure(executions, 1);
    }

    /// @notice A token permit cannot authorize spending a different owner's tokens.
    function check_PermitOwnerBound(address permitOwner) public {
        vm.assume(permitOwner != owner);
        _assertPermitFailure(_permit(permitOwner, ACCOUNT, 1, SESSION_EXPIRY));
    }

    /// @notice A token permit cannot approve an account other than the source account.
    function check_PermitSpenderBound(address spender) public {
        vm.assume(spender != ACCOUNT);
        _assertPermitFailure(_permit(owner, spender, 1, SESSION_EXPIRY));
    }

    /// @notice A token permit cannot authorize an amount beyond the source-session cap.
    function check_PermitAmountCapped(uint256 amount) public {
        vm.assume(amount > SOURCE_CAP);
        _assertPermitFailure(_permit(owner, ACCOUNT, amount, SESSION_EXPIRY));
    }

    /// @notice Token permit deadlines must lie within the current session window.
    function check_PermitDeadlineBound(uint256 deadline) public {
        vm.assume(deadline < START_TIME || deadline > SESSION_EXPIRY);
        _assertPermitFailure(_permit(owner, ACCOUNT, 1, deadline));
    }

    /// @notice Any selector outside transferFrom, approve, and permit is rejected by the source policy.
    function check_UnknownTokenSelectorRejected(bytes4 selector) public {
        vm.assume(selector != IERC20.transferFrom.selector);
        vm.assume(selector != IERC20.approve.selector);
        vm.assume(selector != IERC20Permit.permit.selector);
        Execution[] memory executions = _singleTransfer(1);
        executions[0].callData = abi.encodePacked(selector, bytes32(0), bytes32(0), bytes32(0));
        _assertFundingFailure(executions, 1);
    }

    /// @notice A calldata payload too short to contain a selector is rejected after full claim validation.
    function check_TruncatedSelectorRejected(bytes3 data) public {
        Execution[] memory executions = _singleTransfer(1);
        executions[0].callData = abi.encodePacked(data);
        _assertError(
            _envelope(executions, _claim(1, 0)),
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidOperation.selector)
        );
    }

    /// @notice A transfer with a truncated amount word cannot satisfy the source policy.
    function check_TruncatedTransferAmountRejected(bytes31 partialAmount) public {
        Execution[] memory executions = _singleTransfer(1);
        executions[0].callData = abi.encodePacked(
            IERC20.transferFrom.selector,
            bytes32(uint256(uint160(owner))),
            bytes32(uint256(uint160(ACCOUNT))),
            partialAmount
        );
        _assertError(
            _envelope(executions, _claim(1, 0)),
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidOperation.selector)
        );
    }

    /// @notice A zero-call operation cannot authorize a positive token claim.
    function check_EmptyOperationRejected() public {
        Execution[] memory executions = new Execution[](0);
        _assertFundingFailure(executions, 1);
    }

    /// @notice Each operation mode explicitly supported by the production library passes this funding path.
    function check_SupportedModes(uint8 choice, uint96 amount) public {
        vm.assume(choice < 3);
        vm.assume(amount > 0 && amount <= SOURCE_CAP);
        bytes32 mode = HCAOperationHashLib.ERC7579_ERC1271_MODE;
        if (choice == 1)
            mode = HCAOperationHashLib.ERC7579_EMISSARY_EXECUTION_MODE;
        if (choice == 2)
            mode = HCAOperationHashLib.ERC7579_ERC1271_EMISSARY_EXECUTION_MODE;
        _assertValid(_envelopeWithMode(_singleTransfer(amount), _claim(amount, 0), mode));
    }

    /// @notice Any other compact operation mode is rejected after its signature and digest checks.
    function check_UnsupportedModesRejected(bytes2 prefix) public {
        bytes32 mode = bytes32(prefix);
        vm.assume(!HCAOperationHashLib.isSupportedMode(mode));
        _assertError(
            _envelopeWithMode(_singleTransfer(1), _claim(1, 0), mode),
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidOperation.selector)
        );
    }

    /// @notice A nonzero execution value in the signed operation cannot match the zero-value wire format.
    function check_NonzeroExecutionValueCannotMatchSignedOperation(uint256 value) public {
        vm.assume(value != 0);
        Execution[] memory executions = _singleTransfer(1);
        executions[0].value = value;
        _assertError(_envelope(executions, _claim(1, 0)), _fieldError(10));
    }

    /// @notice Altering the execution amount after signing cannot reuse the original operation commitment.
    function check_OperationCommitmentBindsTransferAmount(uint256 replacement) public {
        vm.assume(replacement != 1);
        FundingEnvelope memory original = _envelope(_singleTransfer(1), _claim(1, 0));
        bytes memory changedOperation =
            _packOperation(HCAOperationHashLib.ERC7579_ERC1271_MODE, _singleTransfer(replacement));
        _assertError(_seal(original.claim, changedOperation), _fieldError(10));
    }

    /// @notice Extra bytes after the declared operation are rejected by production compact parsing.
    function check_TrailingOperationDataRejected(bytes1 trailingByte) public {
        FundingEnvelope memory original = _envelope(_singleTransfer(1), _claim(1, 0));
        _assertError(
            _seal(original.claim, bytes.concat(original.operation, trailingByte)),
            abi.encodeWithSelector(HCAOperationHashLib.InvalidOperationEncoding.selector)
        );
    }

    /// @notice A declared second execution without its bytes is rejected by production compact parsing.
    function check_MissingDeclaredExecutionRejected() public {
        FundingEnvelope memory original = _envelope(_singleTransfer(1), _claim(1, 0));
        original.operation[2] = bytes1(uint8(2));
        _assertError(
            _seal(original.claim, original.operation),
            abi.encodeWithSelector(HCAOperationHashLib.InvalidOperationEncoding.selector)
        );
    }

    /// @notice Requires a source-policy failure for the supplied fixed execution shape.
    function _assertFundingFailure(Execution[] memory executions, uint256 claimedAmount) internal {
        _assertError(
            _envelope(executions, _claim(claimedAmount, 0)),
            abi.encodeWithSelector(HCAFundingSessionValidator.FundingPolicyFailed.selector)
        );
    }

    /// @notice Places a token permit before a valid pull to test the permit's independent policy fields.
    function _assertPermitFailure(Execution memory permitExecution) internal {
        Execution[] memory executions = new Execution[](2);
        executions[0] = permitExecution;
        executions[1] = _transfer(1);
        _assertFundingFailure(executions, 1);
    }
}
