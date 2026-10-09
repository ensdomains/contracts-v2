// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {HCAAccountFixture, HCAFormalOwnerRegistry} from "./account/HCAAccountFixture.sol";

import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";
import {IStandaloneHCAFactory} from "~src/hca/interfaces/IStandaloneHCAFactory.sol";
import {IAddressSet} from "~src/utils/interfaces/IAddressSet.sol";

import {
    ExecutionMode,
    CallType,
    ExecType,
    CALLTYPE_SINGLE,
    CALLTYPE_BATCH,
    EXECTYPE_DEFAULT,
    EXECTYPE_TRY
} from "nexus/lib/ModeLib.sol";
import {MODULE_TYPE_VALIDATOR, MODULE_TYPE_EXECUTOR} from "nexus/types/Constants.sol";

/// @notice Symbolic access and inductive single-step invariants for the account state word.
/// @dev Every nonzero owner and every uint96 nonce is considered with initialized proxy/module
///      storage. Nonce arithmetic is modular; the suite explicitly covers wraparound.
contract HCAAccountStateTest is HCAAccountFixture {
    function check_revokeExactlyWhenOwner(address owner_, address caller, uint96 nonce) public {
        _seed(owner_, nonce);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.revokeSessions, ()));
        if (caller == owner_) {
            assert(ok);
            unchecked {
                _assertState(owner_, nonce + 1);
            }
        } else {
            _assertRevert(ok, data, StandaloneSingleOwnerHCA.CallerNotOwner.selector);
            _assertState(owner_, nonce);
        }
        assert(_implementationOf(address(account)) == address(implementation));
    }

    function check_twoRevocationsAndRejectedInterleaving(
        address owner_,
        address outsider,
        uint96 nonce
    )
        public
    {
        _seed(owner_, nonce);
        vm.assume(outsider != owner_);
        vm.prank(owner_);
        (bool first, ) = address(account).call(abi.encodeCall(account.revokeSessions, ()));
        assert(first);
        vm.prank(outsider);
        (bool middle, bytes memory data) =
            address(account).call(abi.encodeCall(account.revokeSessions, ()));
        _assertRevert(middle, data, StandaloneSingleOwnerHCA.CallerNotOwner.selector);
        vm.prank(owner_);
        (bool last, ) = address(account).call(abi.encodeCall(account.revokeSessions, ()));
        assert(last);
        unchecked {
            _assertState(owner_, nonce + 2);
        }
    }

    function check_nonceWrapPreservesOwner(address owner_) public {
        _seed(owner_, type(uint96).max);
        vm.prank(owner_);
        (bool ok, ) = address(account).call(abi.encodeCall(account.revokeSessions, ()));
        assert(ok);
        _assertState(owner_, 0);
    }

    function check_initializationSetsOwnerOnce(address owner_, address caller) public {
        vm.assume(owner_ != address(0));
        vm.prank(caller);
        (bool ok, ) =
            address(implementation).call(
                abi.encodeCall(implementation.initializeAccount, (abi.encode(owner_)))
            );
        assert(ok);
        (address reported, uint96 nonce) = implementation.ownerAndSessionNonce();
        assert(reported == owner_);
        assert(nonce == 0);
    }

    function check_zeroOwnerInitializationRejected(address caller) public {
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(implementation).call(
                abi.encodeCall(implementation.initializeAccount, (abi.encode(address(0))))
            );
        _assertRevert(ok, data, StandaloneSingleOwnerHCA.OwnerCannotBeZero.selector);
        assert(implementation.owner() == address(0));
    }

    function check_reinitializationPreservesState(
        address owner_,
        uint96 nonce,
        address replacement,
        address caller
    )
        public
    {
        _seed(owner_, nonce);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.initializeAccount, (abi.encode(replacement)))
            );
        _assertRevert(
            ok,
            data,
            replacement == address(0)
                ? StandaloneSingleOwnerHCA.OwnerCannotBeZero.selector
                : StandaloneSingleOwnerHCA.StandaloneHCAAlreadyInitialized.selector
        );
        _assertState(owner_, nonce);
    }

    function check_allModuleMutationsRejected(
        address caller,
        uint256 moduleType,
        address module,
        bytes32 payload,
        bool install
    )
        public
    {
        bytes memory callData = install
            ? abi.encodeCall(account.installModule, (moduleType, module, abi.encode(payload)))
            : abi.encodeCall(account.uninstallModule, (moduleType, module, abi.encode(payload)));
        vm.prank(caller);
        (bool ok, bytes memory data) = address(account).call(callData);
        _assertRevert(ok, data, StandaloneSingleOwnerHCA.NoModuleChangeAllowed.selector);
        _assertState(INITIAL_OWNER, 0);
        // The default validator is immutable and is not in Nexus's dynamic validator list.
        assert(!account.isModuleInstalled(MODULE_TYPE_VALIDATOR, address(modules), ""));
        assert(account.isModuleInstalled(MODULE_TYPE_EXECUTOR, executor, ""));
    }

    function check_executionModeSupportTruthTable(bytes32 mode) public view {
        bytes1 callType = bytes1(mode);
        bytes1 execType = bytes1(mode << 8);
        bool expected =
            (callType == CallType.unwrap(CALLTYPE_SINGLE) ||
                callType == CallType.unwrap(CALLTYPE_BATCH)) &&
            (execType == ExecType.unwrap(EXECTYPE_DEFAULT) ||
                execType == ExecType.unwrap(EXECTYPE_TRY));
        assert(account.supportsExecutionMode(ExecutionMode.wrap(mode)) == expected);
    }

    function check_predecessorApprovalTruthTable(address previous, bool allowed) public {
        predecessorSet.set(previous, allowed);
        assert(implementation.canUpgradeFrom(previous) == allowed);
        assert(account.canUpgradeFrom(previous) == allowed);
    }

    function check_zeroPredecessorSetRejectsAll(address previous) public {
        StandaloneSingleOwnerHCA initial =
            _implementation(IStandaloneHCAFactory(address(0)), IAddressSet(address(0)));
        assert(!initial.canUpgradeFrom(previous));
    }
}


/// @notice Account behavior for arbitrary canonical certificates supplied by its immutable registry.
/// @dev Certificate validity and immutability are the responsibility of the real factory suite.
contract HCAAccountRegistryStateTest is HCAAccountFixture {
    HCAFormalOwnerRegistry internal registry;
    StandaloneSingleOwnerHCA internal registered;

    function setUp() public override {
        super.setUp();
        registry = new HCAFormalOwnerRegistry(proxyFactory);
        registered = _implementation(IStandaloneHCAFactory(address(registry)), predecessorSet);
    }

    function check_certifiedOwnerOverridesLegacySlot(
        address legacyOwner,
        address certifiedOwner,
        uint96 nonce
    )
        public
    {
        vm.store(
            address(registered),
            OWNER_NONCE_SLOT,
            bytes32(uint256(uint160(legacyOwner)) | (uint256(nonce) << 160))
        );
        registry.certify(address(registered), certifiedOwner);
        (address reported, uint96 actualNonce) = registered.ownerAndSessionNonce();
        assert(reported == certifiedOwner);
        assert(registered.owner() == certifiedOwner);
        assert(actualNonce == nonce);
    }

    function check_registryInitializationOnlyDeployer(address caller, address proposed, uint96 nonce)
        public
    {
        vm.assume(proposed != address(0));
        vm.store(address(registered), OWNER_NONCE_SLOT, bytes32(uint256(nonce) << 160));
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(registered).call(
                abi.encodeCall(registered.initializeAccount, (abi.encode(proposed)))
            );
        if (caller == address(proxyFactory)) {
            assert(ok);
        } else {
            _assertRevert(
                ok,
                data,
                StandaloneSingleOwnerHCA.StandaloneHCAAlreadyInitialized.selector
            );
        }
        (address reported, uint96 actualNonce) = registered.ownerAndSessionNonce();
        assert(reported == address(0));
        assert(actualNonce == nonce);
        assert(vm.load(address(registered), OWNER_NONCE_SLOT) == bytes32(uint256(nonce) << 160));
    }

    function check_registryRevokeUsesCertifiedOwner(
        address legacyOwner,
        address certifiedOwner,
        address caller,
        uint96 nonce
    )
        public
    {
        vm.assume(certifiedOwner != address(0));
        vm.store(
            address(registered),
            OWNER_NONCE_SLOT,
            bytes32(uint256(uint160(legacyOwner)) | (uint256(nonce) << 160))
        );
        registry.certify(address(registered), certifiedOwner);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(registered).call(abi.encodeCall(registered.revokeSessions, ()));
        (address reported, uint96 actualNonce) = registered.ownerAndSessionNonce();
        assert(reported == certifiedOwner);
        if (caller == certifiedOwner) {
            assert(ok);
            unchecked {
                assert(actualNonce == nonce + 1);
            }
        } else {
            _assertRevert(ok, data, StandaloneSingleOwnerHCA.CallerNotOwner.selector);
            assert(actualNonce == nonce);
        }
        assert(
            address(uint160(uint256(vm.load(address(registered), OWNER_NONCE_SLOT)))) == legacyOwner
        );
    }
}
