// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

// solhint-disable func-name-mixedcase

import {HCAFundingFixture} from "./funding/HCAFundingFixture.sol";

import {HCAFundingSessionValidator} from "~src/hca/HCAFundingSessionValidator.sol";

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {
    ERC1271_MAGICVALUE,
    VALIDATION_FAILED,
    MODULE_TYPE_VALIDATOR
} from "nexus/types/Constants.sol";

/// @notice Checks funding-session installation, isolation, expiry, and entry-point authorization.
/// @dev Lifecycle sequences contain at most an installation, removal, and replacement. General
///      configuration checks retain all scalar fields; the assumption helper states precisely the
///      live, nonzero domain admitted by onInstall. No arbitrary storage injection is used. Dynamic
///      payloads on the permanently disabled paths have a fixed word-sized shape.
/// @custom:halmos --loop 4
contract HCAFundingLifecycle is HCAFundingFixture {
    /// @notice Every combination containing a zero constructor dependency fails with the production error.
    function check_ConstructorRejectsMissingDependencies(uint8 missingMask) public {
        vm.assume(missingMask > 0 && missingMask < 8);
        address executor = (missingMask & 1) != 0 ? address(0) : EXECUTOR;
        address permit2 = (missingMask & 2) != 0 ? address(0) : PERMIT2;
        address claimRouter = (missingMask & 4) != 0 ? address(0) : address(router);
        bool success;
        bytes memory result;
        try new HCAFundingSessionValidator(executor, permit2, claimRouter) returns (
            HCAFundingSessionValidator
        ) {
            success = true;
        } catch (bytes memory reason) {
            result = reason;
        }
        _assertFailure(
            success,
            result,
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidSession.selector)
        );
    }

    /// @notice Every live, nonzero configuration is stored exactly for its calling account.
    function check_InstallStoresCompleteConfig(
        address account,
        HCAFundingSessionValidator.SessionConfig memory proposed
    )
        public
    {
        vm.assume(account != address(0) && account != ACCOUNT);
        _assumeInstallable(proposed);
        bytes32 established = _sessionHash(ACCOUNT);
        (bool success, ) = _install(account, proposed);
        assert(success);
        assert(validator.isInitialized(account));
        assert(_sessionHash(account) == keccak256(abi.encode(proposed)));
        assert(_sessionHash(ACCOUNT) == established);
    }

    /// @notice Each required nonzero field independently prevents installation when omitted.
    function check_ZeroRequiredFieldRejected(uint8 field) public {
        vm.assume(field < 9);
        HCAFundingSessionValidator.SessionConfig memory proposed = config;
        if (field == 0)
            proposed.permissionId = bytes32(0);
        else if (field == 1)
            proposed.owner = address(0);
        else if (field == 2)
            proposed.sessionKey = address(0);
        else if (field == 3)
            proposed.sourceToken = address(0);
        else if (field == 4)
            proposed.destinationRecipient = address(0);
        else if (field == 5)
            proposed.destinationToken = address(0);
        else if (field == 6)
            proposed.destinationChainId = 0;
        else if (field == 7)
            proposed.maxSourceAmount = 0;
        else
            proposed.maxDestinationAmount = 0;
        bytes32 established = _sessionHash(ACCOUNT);
        bytes32 emptyBefore = _sessionHash(OTHER_ACCOUNT);
        (bool success, bytes memory result) = _install(OTHER_ACCOUNT, proposed);
        _assertFailure(
            success,
            result,
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidSession.selector)
        );
        assert(!validator.isInitialized(OTHER_ACCOUNT));
        assert(_sessionHash(OTHER_ACCOUNT) == emptyBefore);
        assert(_sessionHash(ACCOUNT) == established);
    }

    /// @notice Installation requires an expiry strictly later than the installation timestamp.
    function check_ExpiredInstallationRejected(uint48 expiry) public {
        vm.assume(expiry <= START_TIME);
        HCAFundingSessionValidator.SessionConfig memory proposed = config;
        proposed.validUntil = expiry;
        bytes32 emptyBefore = _sessionHash(OTHER_ACCOUNT);
        (bool success, bytes memory result) = _install(OTHER_ACCOUNT, proposed);
        _assertFailure(
            success,
            result,
            abi.encodeWithSelector(HCAFundingSessionValidator.SessionExpired.selector)
        );
        assert(_sessionHash(OTHER_ACCOUNT) == emptyBefore);
        assert(!validator.isInitialized(OTHER_ACCOUNT));
    }

    /// @notice A truncated configuration cannot initialize or partially modify an account.
    function check_TruncatedInstallDataRejected(bytes32 prefix) public {
        bytes32 emptyBefore = _sessionHash(OTHER_ACCOUNT);
        vm.prank(OTHER_ACCOUNT);
        (bool success, ) =
            address(validator).call(abi.encodeCall(validator.onInstall, (abi.encodePacked(prefix))));
        assert(!success);
        assert(_sessionHash(OTHER_ACCOUNT) == emptyBefore);
        assert(!validator.isInitialized(OTHER_ACCOUNT));
    }

    /// @notice Duplicate installation is rejected before parsing replacement data and preserves the session.
    function check_DuplicateInstallPreservesSession(bytes32 replacementData) public {
        bytes32 beforeConfig = _sessionHash(ACCOUNT);
        vm.prank(ACCOUNT);
        (bool success, bytes memory result) =
            address(validator).call(
                abi.encodeCall(validator.onInstall, (abi.encodePacked(replacementData)))
            );
        _assertFailure(
            success,
            result,
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidSession.selector)
        );
        assert(_sessionHash(ACCOUNT) == beforeConfig);
        assert(validator.isInitialized(ACCOUNT));
    }

    /// @notice Calling uninstall from any other account cannot erase the established account's session.
    function check_UninstallIsAccountIsolated(address caller) public {
        vm.assume(caller != ACCOUNT);
        bytes32 beforeConfig = _sessionHash(ACCOUNT);
        (bool success, ) = _uninstall(caller);
        assert(success);
        assert(_sessionHash(ACCOUNT) == beforeConfig);
        assert(validator.isInitialized(ACCOUNT));
    }

    /// @notice Removal clears every configuration field and is idempotent.
    function check_UninstallClearsEntireSession() public {
        (bool firstSuccess, ) = _uninstall(ACCOUNT);
        assert(firstSuccess);
        HCAFundingSessionValidator.SessionConfig memory emptyConfig;
        assert(_sessionHash(ACCOUNT) == keccak256(abi.encode(emptyConfig)));
        assert(!validator.isInitialized(ACCOUNT));
        (bool secondSuccess, ) = _uninstall(ACCOUNT);
        assert(secondSuccess);
        assert(_sessionHash(ACCOUNT) == keccak256(abi.encode(emptyConfig)));
    }

    /// @notice Removal allows a complete live replacement without retaining any prior configuration field.
    function check_UninstallAllowsCompleteReplacement(
        HCAFundingSessionValidator.SessionConfig memory replacement
    )
        public
    {
        _assumeInstallable(replacement);
        (bool removed, ) = _uninstall(ACCOUNT);
        assert(removed);
        (bool installed, ) = _install(ACCOUNT, replacement);
        assert(installed);
        assert(_sessionHash(ACCOUNT) == keccak256(abi.encode(replacement)));
        assert(validator.isInitialized(ACCOUNT));
    }

    /// @notice A proof valid before uninstall is rejected after uninstall and works after identical reinstall.
    function check_UninstallRevokesAndReinstallRestoresValidation(uint256 nonce) public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, nonce));
        _assertValid(envelope);
        (bool removed, ) = _uninstall(ACCOUNT);
        assert(removed);
        _assertError(
            envelope,
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidSession.selector)
        );
        (bool installed, ) = _install(ACCOUNT, config);
        assert(installed);
        _assertValid(envelope);
    }

    /// @notice Validation includes the exact expiry timestamp and rejects every later timestamp.
    function check_ValidationExpiryBoundary(uint256 timestamp) public {
        vm.assume(timestamp >= START_TIME);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        vm.warp(timestamp);
        if (timestamp <= SESSION_EXPIRY) {
            _assertValid(envelope);
        } else {
            _assertError(
                envelope,
                abi.encodeWithSelector(HCAFundingSessionValidator.SessionExpired.selector)
            );
        }
        assert(validator.isInitialized(ACCOUNT));
    }

    /// @notice Only the Permit2 caller and executor precheck can use the funding signature entry point.
    function check_SignatureSenderGate(address sender) public {
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        (bool success, bytes memory result) =
            _validate(ACCOUNT, sender, envelope.digest, envelope.data);
        if (sender == PERMIT2 || sender == EXECUTOR) {
            assert(success);
            assert(result.length == 32);
            assert(abi.decode(result, (bytes4)) == ERC1271_MAGICVALUE);
        } else {
            _assertFailure(
                success,
                result,
                abi.encodeWithSelector(HCAFundingSessionValidator.UnauthorizedCaller.selector)
            );
        }
    }

    /// @notice An account without an installed session cannot borrow the established account's proof.
    function check_UninitializedAccountCannotUseEnvelope(address account) public {
        vm.assume(account != ACCOUNT);
        FundingEnvelope memory envelope = _envelope(_singleTransfer(1), _claim(1, 0));
        (bool success, bytes memory result) =
            _validate(account, PERMIT2, envelope.digest, envelope.data);
        _assertFailure(
            success,
            result,
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidSession.selector)
        );
        assert(!validator.isInitialized(account));
    }

    /// @notice Well-formed ERC-4337 operations always return the production failure constant.
    /// @dev Every dynamic field uses one symbolic word; scalar sender, nonce, and hash remain symbolic.
    function check_UserOperationPathAlwaysDisabled(
        address sender,
        uint256 nonce,
        bytes32 digest,
        bytes32 data
    )
        public
    {
        PackedUserOperation memory userOp;
        userOp.sender = sender;
        userOp.nonce = nonce;
        userOp.initCode = abi.encodePacked(data);
        userOp.callData = abi.encodePacked(data);
        userOp.paymasterAndData = abi.encodePacked(data);
        userOp.signature = abi.encodePacked(data);
        bytes32 beforeConfig = _sessionHash(ACCOUNT);
        (bool success, bytes memory result) =
            address(validator).call(abi.encodeCall(validator.validateUserOp, (userOp, digest)));
        assert(success);
        assert(result.length == 32);
        assert(abi.decode(result, (uint256)) == VALIDATION_FAILED);
        assert(_sessionHash(ACCOUNT) == beforeConfig);
    }

    /// @notice The separate emissary execution path is rejected for every symbolic scalar in this shape.
    function check_DirectExecutionPathAlwaysDisabled(
        address account,
        bytes32 digest,
        bytes32 data,
        bytes32 operationData
    )
        public
    {
        HCAFundingSessionValidator.Operation memory operation =
            HCAFundingSessionValidator.Operation({data: abi.encodePacked(operationData)});
        bytes32 beforeConfig = _sessionHash(ACCOUNT);
        (bool success, bytes memory result) =
            address(validator).call(
                abi.encodeCall(
                    validator.verifyExecution,
                    (account, digest, abi.encodePacked(data), operation)
                )
            );
        _assertFailure(
            success,
            result,
            abi.encodeWithSelector(HCAFundingSessionValidator.InvalidSession.selector)
        );
        assert(_sessionHash(ACCOUNT) == beforeConfig);
    }

    /// @notice Permissions remain disabled for every account and identifier so proofs cannot be omitted.
    function check_PermissionIsNeverPersistentlyEnabled(address account, bytes32 permissionId)
        public
        view
    {
        assert(!validator.isPermissionEnabled(account, permissionId));
    }

    /// @notice The module advertises exactly the validator module type.
    function check_ModuleTypeIsExact(uint256 moduleType) public view {
        assert(validator.isModuleType(moduleType) == (moduleType == MODULE_TYPE_VALIDATOR));
    }

    /// @notice Restricts a symbolic configuration exactly to the live nonzero installation domain.
    function _assumeInstallable(HCAFundingSessionValidator.SessionConfig memory proposed)
        internal
        pure
    {
        vm.assume(proposed.permissionId != bytes32(0));
        vm.assume(proposed.owner != address(0));
        vm.assume(proposed.sessionKey != address(0));
        vm.assume(proposed.sourceToken != address(0));
        vm.assume(proposed.destinationRecipient != address(0));
        vm.assume(proposed.destinationToken != address(0));
        vm.assume(proposed.destinationChainId != 0);
        vm.assume(proposed.maxSourceAmount != 0);
        vm.assume(proposed.maxDestinationAmount != 0);
        vm.assume(proposed.validUntil > START_TIME);
    }
}
