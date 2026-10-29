// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {HCAAccountFixture} from "./account/HCAAccountFixture.sol";

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {Nexus} from "nexus/Nexus.sol";
import {IBaseAccountEventsAndErrors} from "nexus/interfaces/base/IBaseAccountEventsAndErrors.sol";
import {
    IModuleManagerEventsAndErrors
} from "nexus/interfaces/base/IModuleManagerEventsAndErrors.sol";
import {ExecutionMode, CallType, CALLTYPE_DELEGATECALL} from "nexus/lib/ModeLib.sol";
import {
    MODE_VALIDATION,
    VALIDATION_FAILED,
    ERC1271_INVALID,
    SUPPORTS_ERC7739
} from "nexus/types/Constants.sol";

/// @notice Account dispatch and calldata-filter proofs over the real proxy and account bytecode.
/// @dev The fixed validator returns a symbolic result; these tests establish the account's gate
///      and forwarding behavior. Owner/session signature authorization is proved in its own suite.
contract HCAAccountValidationTest is HCAAccountFixture {
    function check_nonceGateAndValidatorForwarding(uint256 nonce, uint256 result, bytes32 hash)
        public
    {
        modules.configureValidation(result);
        PackedUserOperation memory op = _operation(nonce, "");
        vm.prank(ENTRY_POINT);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.validateUserOp, (op, hash, 0)));
        assert(ok);
        bool allowed =
            uint8(nonce >> 224) == uint8(MODE_VALIDATION) &&
            address(uint160(nonce >> 64)) == address(0);
        assert(abi.decode(data, (uint256)) == (allowed ? result : VALIDATION_FAILED));
        assert(modules.validations() == (allowed ? 1 : 0));
        if (allowed) {
            assert(modules.lastHash() == hash);
            assert(modules.lastNonce() == nonce);
            assert(modules.lastAccount() == address(account));
        }
        _assertState(INITIAL_OWNER, 0);
    }

    function check_userOpOnlyEntryPoint(address caller, uint256 nonce, bytes32 hash) public {
        vm.assume(caller != ENTRY_POINT);
        PackedUserOperation memory op = _operation(nonce, "");
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.validateUserOp, (op, hash, 0)));
        _assertRevert(ok, data, IBaseAccountEventsAndErrors.AccountAccessUnauthorized.selector);
        assert(modules.validations() == 0);
        _assertState(INITIAL_OWNER, 0);
    }

    function check_executeCalldataDelegatecallGate(bytes32 mode, bool wrapped) public {
        bytes memory callData = abi.encodeCall(account.execute, (ExecutionMode.wrap(mode), ""));
        if (wrapped)
            callData = bytes.concat(Nexus.executeUserOp.selector, callData);
        bool allowed = bytes1(mode) != CallType.unwrap(CALLTYPE_DELEGATECALL);
        _assertValidationGate(callData, allowed);
    }

    function check_doubleUserOpWrapperRejected(bytes32 suffix) public {
        _assertValidationGate(
            abi.encodePacked(Nexus.executeUserOp.selector, Nexus.executeUserOp.selector, suffix),
            false
        );
    }

    function check_otherCallSelectorsForwarded(bytes4 selector, bytes32 suffix, bool wrapped)
        public
    {
        vm.assume(selector != Nexus.execute.selector);
        vm.assume(selector != Nexus.executeUserOp.selector);
        bytes memory callData = abi.encodePacked(selector, suffix);
        if (wrapped)
            callData = bytes.concat(Nexus.executeUserOp.selector, callData);
        _assertValidationGate(callData, true);
    }

    function check_truncatedExecuteModeRejected(bytes31 suffix, bool wrapped) public {
        bytes memory callData = abi.encodePacked(Nexus.execute.selector, suffix);
        if (wrapped)
            callData = bytes.concat(Nexus.executeUserOp.selector, callData);
        _assertValidationGate(callData, false);
    }

    function check_selectorOnlyExecuteRejected(bool wrapped) public {
        bytes memory callData = abi.encodePacked(Nexus.execute.selector);
        if (wrapped)
            callData = bytes.concat(Nexus.executeUserOp.selector, callData);
        _assertValidationGate(callData, false);
    }

    function check_shortCallDataForwarded(bytes1 one, bytes2 two, bytes3 three, bool wrapped)
        public
    {
        bytes memory prefix = wrapped ? abi.encodePacked(Nexus.executeUserOp.selector) : bytes("");
        _assertValidationGate(prefix, true);
        _assertValidationGate(bytes.concat(prefix, one), true);
        _assertValidationGate(bytes.concat(prefix, two), true);
        _assertValidationGate(bytes.concat(prefix, three), true);
    }

    function check_prefundBoundedByBalance(
        uint128 initialBalance,
        uint128 requested,
        bool nonceAccepted
    )
        public
    {
        vm.deal(address(account), initialBalance);
        vm.deal(ENTRY_POINT, 0);
        uint256 nonce = nonceAccepted ? 0 : uint256(1) << 224;
        PackedUserOperation memory op = _operation(nonce, "");
        vm.prank(ENTRY_POINT);
        (bool ok, ) =
            address(account).call(
                abi.encodeCall(account.validateUserOp, (op, bytes32(0), requested))
            );
        assert(ok);
        uint256 transferred = requested <= initialBalance ? requested : 0;
        assert(ENTRY_POINT.balance == transferred);
        assert(address(account).balance == initialBalance - transferred);
        _assertState(INITIAL_OWNER, 0);
    }

    function check_signatureForwardsOriginalSenderHashAndSuffix(
        address sender,
        bytes32 hash,
        bytes32 suffix
    )
        public
    {
        bytes memory innerSignature = abi.encode(suffix);
        modules.expectSignatureInputs(sender, hash, innerSignature);
        bytes4 expected = modules.signatureResult();
        vm.prank(sender);
        (bool ok, bytes memory data) =
            address(account).staticcall(
                abi.encodeCall(
                    account.isValidSignature,
                    (hash, abi.encodePacked(address(0), innerSignature))
                )
            );
        assert(ok);
        assert(abi.decode(data, (bytes4)) == expected);
    }

    function check_signatureResultAndRevertMapping(bytes4 result, bool shouldRevert, bytes32 hash)
        public
    {
        modules.configureSignature(result, shouldRevert);
        (bool ok, bytes memory data) =
            address(account).staticcall(
                abi.encodeCall(account.isValidSignature, (hash, abi.encodePacked(address(0))))
            );
        assert(ok);
        assert(abi.decode(data, (bytes4)) == (shouldRevert ? ERC1271_INVALID : result));
    }

    function check_nonDefaultValidatorPrefixRejected(address validator, bytes32 hash, bytes32 suffix)
        public
        view
    {
        vm.assume(validator != address(0));
        (bool ok, bytes memory data) =
            address(account).staticcall(
                abi.encodeCall(account.isValidSignature, (hash, abi.encodePacked(validator, suffix)))
            );
        _assertRevert(ok, data, IModuleManagerEventsAndErrors.ValidatorNotInstalled.selector);
    }

    function check_shortNonDetectionSignatureRejected(bytes19 signature, bytes32 hash) public view {
        (bool ok, ) =
            address(account).staticcall(
                abi.encodeCall(account.isValidSignature, (hash, abi.encodePacked(signature)))
            );
        assert(!ok);
    }

    function check_erc7739DetectionResult(bytes4 support) public {
        modules.configureSignature(support, false);
        bytes32 detectionHash = bytes32((type(uint256).max / 0xffff) * 0x7739);
        (bool ok, bytes memory data) =
            address(account).staticcall(
                abi.encodeCall(account.isValidSignature, (detectionHash, ""))
            );
        assert(ok);
        bytes4 expected = bytes2(support) == bytes2(SUPPORTS_ERC7739) ? support : ERC1271_INVALID;
        assert(abi.decode(data, (bytes4)) == expected);
    }

    function _operation(uint256 nonce, bytes memory callData)
        internal
        view
        returns (PackedUserOperation memory op)
    {
        op.sender = address(account);
        op.nonce = nonce;
        op.callData = callData;
    }

    function _assertValidationGate(bytes memory callData, bool allowed) internal {
        uint256 before = modules.validations();
        PackedUserOperation memory op = _operation(0, callData);
        vm.prank(ENTRY_POINT);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.validateUserOp, (op, bytes32(0), 0)));
        assert(ok);
        assert(
            abi.decode(data, (uint256)) ==
            (allowed ? modules.validationResult() : VALIDATION_FAILED)
        );
        assert(modules.validations() == before + (allowed ? 1 : 0));
    }
}
