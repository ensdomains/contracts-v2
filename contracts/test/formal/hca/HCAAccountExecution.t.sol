// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {HCAAccountFixture, HCAFormalCallTarget} from "./account/HCAAccountFixture.sol";

import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";

import {Execution} from "nexus/types/DataTypes.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {ComposableExecution} from "composability/types/ComposabilityDataTypes.sol";
import {Nexus} from "nexus/Nexus.sol";
import {ExecLib} from "nexus/lib/ExecLib.sol";
import {
    ExecutionMode,
    ModeLib,
    CallType,
    ExecType,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    CALLTYPE_DELEGATECALL,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY
} from "nexus/lib/ModeLib.sol";
import {IBaseAccountEventsAndErrors} from "nexus/interfaces/base/IBaseAccountEventsAndErrors.sol";
import {
    IModuleManagerEventsAndErrors
} from "nexus/interfaces/base/IModuleManagerEventsAndErrors.sol";
import {
    IExecutionHelperEventsAndErrors
} from "nexus/interfaces/base/IExecutionHelperEventsAndErrors.sol";
import {IERC7484} from "nexus/interfaces/IERC7484.sol";
import {CallContextChecker} from "solady/utils/CallContextChecker.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

/// @notice Owner, executor, EntryPoint, rollback, and explicit callback traces through the real proxy.
/// @dev Batches are bounded to two calls. Targets have explicit success, failure, and callback
///      behavior; these are not proofs of arbitrary external contract behavior or the EntryPoint.
contract HCAAccountExecutionTest is HCAAccountFixture {
    function check_ownerBatchAuthorization(
        address owner_,
        address caller,
        uint96 nonce,
        uint256 value_
    )
        public
    {
        _seed(owner_, nonce);
        Execution[] memory calls = new Execution[](1);
        calls[0] = _writeCall(firstTarget, value_);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.executeByOwner, (calls)));
        if (caller == owner_) {
            assert(ok);
            assert(firstTarget.value() == value_);
            assert(firstTarget.caller() == address(account));
            assert(firstTarget.calls() == 1);
        } else {
            _assertRevert(ok, data, StandaloneSingleOwnerHCA.CallerNotOwner.selector);
            assert(firstTarget.calls() == 0);
        }
        _assertState(owner_, nonce);
    }

    function check_ownerTwoCallOrdering(uint256 first, uint256 last, bool sameTarget, uint96 nonce)
        public
    {
        _seed(INITIAL_OWNER, nonce);
        Execution[] memory calls = new Execution[](2);
        calls[0] = _writeCall(firstTarget, first);
        calls[1] = _writeCall(sameTarget ? firstTarget : secondTarget, last);
        vm.prank(INITIAL_OWNER);
        (bool ok, ) = address(account).call(abi.encodeCall(account.executeByOwner, (calls)));
        assert(ok);
        assert(firstTarget.value() == (sameTarget ? last : first));
        assert(firstTarget.calls() == (sameTarget ? 2 : 1));
        assert(firstTarget.caller() == address(account));
        assert(secondTarget.value() == (sameTarget ? 0 : last));
        assert(secondTarget.calls() == (sameTarget ? 0 : 1));
        _assertState(INITIAL_OWNER, nonce);
    }

    function check_ownerBatchFailureRollsBack(uint256 value_, uint96 nonce) public {
        _seed(INITIAL_OWNER, nonce);
        Execution[] memory calls = new Execution[](2);
        calls[0] = _writeCall(firstTarget, value_);
        calls[1] = Execution(address(secondTarget), 0, abi.encodeCall(secondTarget.fail, ()));
        vm.prank(INITIAL_OWNER);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.executeByOwner, (calls)));
        _assertRevert(ok, data, HCAFormalCallTarget.DeliberateFailure.selector);
        assert(firstTarget.calls() == 0);
        assert(firstTarget.value() == 0);
        _assertState(INITIAL_OWNER, nonce);
    }

    function check_ownerEmptyBatchPreservesState(address owner_, uint96 nonce) public {
        _seed(owner_, nonce);
        Execution[] memory calls = new Execution[](0);
        vm.prank(owner_);
        (bool ok, ) = address(account).call(abi.encodeCall(account.executeByOwner, (calls)));
        assert(ok);
        _assertState(owner_, nonce);
    }

    function check_ownerBatchTransfersValue(uint128 amount, uint128 remaining, uint256 value_)
        public
    {
        vm.deal(address(account), uint256(amount) + remaining);
        vm.deal(address(firstTarget), 0);
        Execution[] memory calls = new Execution[](1);
        calls[0] = _writeCall(firstTarget, value_);
        calls[0].value = amount;
        vm.prank(INITIAL_OWNER);
        (bool ok, ) = address(account).call(abi.encodeCall(account.executeByOwner, (calls)));
        assert(ok);
        assert(address(firstTarget).balance == amount);
        assert(address(account).balance == remaining);
        assert(firstTarget.value() == value_);
    }

    function check_directImplementationCannotExecute(address caller, uint256 value_) public {
        Execution[] memory calls = new Execution[](1);
        calls[0] = _writeCall(firstTarget, value_);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(implementation).call(abi.encodeCall(account.executeByOwner, (calls)));
        _assertRevert(ok, data, CallContextChecker.UnauthorizedCallContext.selector);
        assert(firstTarget.calls() == 0);
    }

    function check_ownerSelfCallDoesNotImpersonateOwner(address owner_, uint96 nonce) public {
        _seed(owner_, nonce);
        vm.assume(owner_ != address(account));
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution(address(account), 0, abi.encodeCall(account.revokeSessions, ()));
        vm.prank(owner_);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.executeByOwner, (calls)));
        _assertRevert(ok, data, StandaloneSingleOwnerHCA.CallerNotOwner.selector);
        _assertState(owner_, nonce);
    }

    function check_callbackRevokeUsesCallbackCaller(address owner_, uint96 nonce) public {
        _seed(owner_, nonce);
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution(
            address(firstTarget),
            0,
            abi.encodeCall(
                firstTarget.tryCallback,
                (address(account), abi.encodeCall(account.revokeSessions, ()))
            )
        );
        vm.prank(owner_);
        (bool ok, ) = address(account).call(abi.encodeCall(account.executeByOwner, (calls)));
        assert(ok);
        bool authorized = owner_ == address(firstTarget);
        assert(firstTarget.callbackSucceeded() == authorized);
        unchecked {
            _assertState(owner_, authorized ? nonce + 1 : nonce);
        }
    }

    function check_executorSingleAuthorization(address caller, uint256 value_, bool tryMode) public {
        ExecutionMode mode = tryMode ? ModeLib.encodeTrySingle() : ModeLib.encodeSimpleSingle();
        bytes memory encoded =
            ExecLib.encodeSingle(
                address(firstTarget),
                0,
                abi.encodeCall(firstTarget.write, (value_))
            );
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.executeFromExecutor, (mode, encoded)));
        if (caller == executor) {
            assert(ok);
            assert(firstTarget.calls() == 1);
            assert(firstTarget.value() == value_);
            assert(firstTarget.caller() == address(account));
            assert(abi.decode(data, (bytes[])).length == 1);
        } else {
            _assertRevert(ok, data, IModuleManagerEventsAndErrors.InvalidModule.selector);
            assert(firstTarget.calls() == 0);
        }
        _assertState(INITIAL_OWNER, 0);
    }

    function check_executorDelegatecallAlwaysRejected(uint248 remainingMode, uint256 payload)
        public
    {
        bytes32 mode =
            bytes32((uint256(uint8(CallType.unwrap(CALLTYPE_DELEGATECALL))) << 248) | remainingMode);
        bytes memory encoded =
            abi.encodePacked(address(firstTarget), abi.encodeCall(firstTarget.write, (payload)));
        vm.prank(executor);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.executeFromExecutor, (ExecutionMode.wrap(mode), encoded))
            );
        _assertRevert(ok, data, StandaloneSingleOwnerHCA.DelegateCallNotAllowed.selector);
        assert(firstTarget.calls() == 0);
        _assertState(INITIAL_OWNER, 0);
    }

    function check_executorBatchAtomicVersusTry(uint256 value_, bool tryMode) public {
        Execution[] memory calls = new Execution[](2);
        calls[0] = Execution(address(firstTarget), 0, abi.encodeCall(firstTarget.fail, ()));
        calls[1] = _writeCall(secondTarget, value_);
        ExecutionMode mode = tryMode ? ModeLib.encodeTryBatch() : ModeLib.encodeSimpleBatch();
        vm.prank(executor);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.executeFromExecutor, (mode, ExecLib.encodeBatch(calls)))
            );
        if (tryMode) {
            assert(ok);
            bytes[] memory results = abi.decode(data, (bytes[]));
            assert(results.length == 2);
            assert(_selector(results[0]) == HCAFormalCallTarget.DeliberateFailure.selector);
            assert(secondTarget.value() == value_);
            assert(secondTarget.calls() == 1);
        } else {
            _assertRevert(ok, data, HCAFormalCallTarget.DeliberateFailure.selector);
            assert(secondTarget.calls() == 0);
        }
        _assertState(INITIAL_OWNER, 0);
    }

    function check_executorUnknownCallTypeRejected(bytes1 callType, uint248 remainingMode) public {
        vm.assume(callType != CallType.unwrap(CALLTYPE_SINGLE));
        vm.assume(callType != CallType.unwrap(CALLTYPE_BATCH));
        vm.assume(callType != CallType.unwrap(CALLTYPE_DELEGATECALL));
        bytes32 mode = bytes32((uint256(uint8(callType)) << 248) | remainingMode);
        vm.prank(executor);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.executeFromExecutor, (ExecutionMode.wrap(mode), ""))
            );
        _assertRevert(ok, data, IModuleManagerEventsAndErrors.UnsupportedCallType.selector);
        _assertState(INITIAL_OWNER, 0);
    }

    function check_executorUnknownExecTypeRejected(bytes1 execType, bool batch, uint240 payload)
        public
    {
        vm.assume(execType != ExecType.unwrap(EXECTYPE_DEFAULT));
        vm.assume(execType != ExecType.unwrap(EXECTYPE_TRY));
        bytes1 callType = CallType.unwrap(batch ? CALLTYPE_BATCH : CALLTYPE_SINGLE);
        bytes32 mode =
            bytes32((uint256(uint8(callType)) << 248) | (uint256(uint8(execType)) << 240) | payload);
        Execution[] memory calls = new Execution[](1);
        calls[0] = _writeCall(firstTarget, 1);
        bytes memory encoded = batch
            ? ExecLib.encodeBatch(calls)
            : ExecLib.encodeSingle(calls[0].target, 0, calls[0].callData);
        vm.prank(executor);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.executeFromExecutor, (ExecutionMode.wrap(mode), encoded))
            );
        _assertRevert(ok, data, IExecutionHelperEventsAndErrors.UnsupportedExecType.selector);
        assert(firstTarget.calls() == 0);
        _assertState(INITIAL_OWNER, 0);
    }

    function check_executorSingleFailureDefaultVersusTry(bool tryMode) public {
        ExecutionMode mode = tryMode ? ModeLib.encodeTrySingle() : ModeLib.encodeSimpleSingle();
        bytes memory encoded =
            ExecLib.encodeSingle(address(firstTarget), 0, abi.encodeCall(firstTarget.fail, ()));
        vm.prank(executor);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.executeFromExecutor, (mode, encoded)));
        if (tryMode) {
            assert(ok);
            bytes[] memory results = abi.decode(data, (bytes[]));
            assert(results.length == 1);
            assert(_selector(results[0]) == HCAFormalCallTarget.DeliberateFailure.selector);
        } else {
            _assertRevert(ok, data, HCAFormalCallTarget.DeliberateFailure.selector);
        }
        _assertState(INITIAL_OWNER, 0);
    }

    function check_executorSelfCallCannotRevokeSessions(uint96 nonce) public {
        _seed(INITIAL_OWNER, nonce);
        bytes memory encoded =
            ExecLib.encodeSingle(address(account), 0, abi.encodeCall(account.revokeSessions, ()));
        vm.prank(executor);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.executeFromExecutor, (ModeLib.encodeSimpleSingle(), encoded))
            );
        _assertRevert(ok, data, StandaloneSingleOwnerHCA.CallerNotOwner.selector);
        _assertState(INITIAL_OWNER, nonce);
    }

    function check_entryPointExecutionAuthorization(address caller, uint256 value_) public {
        bytes memory encoded =
            ExecLib.encodeSingle(
                address(firstTarget),
                0,
                abi.encodeCall(firstTarget.write, (value_))
            );
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.execute, (ModeLib.encodeSimpleSingle(), encoded))
            );
        if (caller == ENTRY_POINT) {
            assert(ok);
            assert(firstTarget.value() == value_);
            assert(firstTarget.calls() == 1);
            assert(firstTarget.caller() == address(account));
        } else {
            _assertRevert(ok, data, IBaseAccountEventsAndErrors.AccountAccessUnauthorized.selector);
            assert(firstTarget.calls() == 0);
        }
    }

    function check_userOpExecutionAuthorization(address caller, uint256 value_) public {
        bytes memory encoded =
            ExecLib.encodeSingle(
                address(firstTarget),
                0,
                abi.encodeCall(firstTarget.write, (value_))
            );
        PackedUserOperation memory op;
        op.sender = address(account);
        op.callData = bytes.concat(
            Nexus.executeUserOp.selector,
            abi.encodeCall(account.execute, (ModeLib.encodeSimpleSingle(), encoded))
        );
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.executeUserOp, (op, bytes32(0))));
        if (caller == ENTRY_POINT) {
            assert(ok);
            assert(firstTarget.calls() == 1);
            assert(firstTarget.value() == value_);
            assert(firstTarget.caller() == address(account));
        } else {
            _assertRevert(ok, data, IBaseAccountEventsAndErrors.AccountAccessUnauthorized.selector);
            assert(firstTarget.calls() == 0);
        }
    }

    function check_composableEntryRequiresEntryPoint(address caller) public {
        ComposableExecution[] memory calls = new ComposableExecution[](0);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.executeComposable, (calls)));
        if (caller == ENTRY_POINT)
            assert(ok);
        else
            _assertRevert(ok, data, IBaseAccountEventsAndErrors.AccountAccessUnauthorized.selector);
        _assertState(INITIAL_OWNER, 0);
    }

    function check_registryEntryRequiresSelf(address caller, address registry, uint8 threshold)
        public
    {
        address[] memory attesters = new address[](0);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.setRegistry, (IERC7484(registry), attesters, threshold))
            );
        if (caller == address(account))
            assert(ok);
        else
            _assertRevert(ok, data, IBaseAccountEventsAndErrors.AccountAccessUnauthorized.selector);
        _assertState(INITIAL_OWNER, 0);
    }

    function check_depositWithdrawalRejectsOutsiders(
        address caller,
        address recipient,
        uint256 amount
    )
        public
    {
        vm.assume(caller != ENTRY_POINT && caller != address(account));
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.withdrawDepositTo, (payable(recipient), amount))
            );
        _assertRevert(ok, data, IBaseAccountEventsAndErrors.AccountAccessUnauthorized.selector);
    }

    function check_nftCallbacksRejected(bytes32 suffix) public {
        _nftRejected(IERC721Receiver.onERC721Received.selector, suffix);
        _nftRejected(IERC1155Receiver.onERC1155Received.selector, suffix);
        _nftRejected(IERC1155Receiver.onERC1155BatchReceived.selector, suffix);
        _assertState(INITIAL_OWNER, 0);
    }

    function _nftRejected(bytes4 selector, bytes32 suffix) internal {
        (bool ok, bytes memory data) = address(account).call(abi.encodePacked(selector, suffix));
        _assertRevert(ok, data, StandaloneSingleOwnerHCA.NoNFTAllowed.selector);
    }
}
