// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {HCAAccountFixture} from "./account/HCAAccountFixture.sol";

import {StandaloneSingleOwnerHCA} from "~src/hca/StandaloneSingleOwnerHCA.sol";
import {IStandaloneHCAFactory} from "~src/hca/interfaces/IStandaloneHCAFactory.sol";
import {IAddressSet} from "~src/utils/interfaces/IAddressSet.sol";

import {IUUPSProxy} from "@ensdomains/verifiable-factory/IUUPSProxy.sol";
import {Execution} from "nexus/types/DataTypes.sol";
import {CallContextChecker} from "solady/utils/CallContextChecker.sol";

/// @notice Upgrade authorization and state-preservation proofs through both real proxy layers.
/// @dev Success targets are freshly deployed copies of the production HCA with compatible
///      ownership configuration. DAO-approved arbitrary implementation code is outside this claim.
contract HCAAccountUpgradesTest is HCAAccountFixture {
    StandaloneSingleOwnerHCA internal next;

    function setUp() public override {
        super.setUp();
        next = _implementation(IStandaloneHCAFactory(address(0)), predecessorSet);
    }

    function check_upgradeRequiresOwnerAndBothApprovals(
        address owner_,
        address caller,
        uint96 nonce,
        bool targetApproved,
        bool predecessorApproved
    )
        public
    {
        _seed(owner_, nonce);
        targetSet.set(address(next), targetApproved);
        predecessorSet.set(address(implementation), predecessorApproved);
        bytes32 legacyImplementationSlot = bytes32(uint256(uint160(address(account))));
        bytes32 oldLegacy = vm.load(address(account), legacyImplementationSlot);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.upgradeToAndCall, (address(next), "")));
        bool permitted = caller == owner_ && targetApproved && predecessorApproved;
        assert(ok == permitted);
        assert(
            _implementationOf(address(account)) ==
            (permitted ? address(next) : address(implementation))
        );
        assert(
            vm.load(address(account), legacyImplementationSlot) ==
            (permitted ? bytes32(uint256(uint160(address(next)))) : oldLegacy)
        );
        if (!predecessorApproved) {
            assert(_selector(data) == IUUPSProxy.InvalidUpgradeTarget.selector);
        } else if (caller != owner_) {
            assert(_selector(data) == StandaloneSingleOwnerHCA.CallerNotOwner.selector);
        } else if (!targetApproved) {
            assert(_selector(data) == StandaloneSingleOwnerHCA.UpgradeTargetNotApproved.selector);
        }
        _assertState(owner_, nonce);
    }

    function check_upgradeInitializerRetainsOriginalCaller(address owner_, uint96 nonce) public {
        _seed(owner_, nonce);
        _approve();
        vm.prank(owner_);
        (bool ok, ) =
            address(account).call(
                abi.encodeCall(
                    account.upgradeToAndCall,
                    (address(next), abi.encodeCall(account.revokeSessions, ()))
                )
            );
        assert(ok);
        assert(_implementationOf(address(account)) == address(next));
        unchecked {
            _assertState(owner_, nonce + 1);
        }
    }

    function check_failingUpgradeInitializerRollsBackImplementationAndOwnerState(
        address owner_,
        uint96 nonce
    )
        public
    {
        _seed(owner_, nonce);
        _approve();
        bytes32 slot = bytes32(uint256(uint160(address(account))));
        bytes32 oldLegacy = vm.load(address(account), slot);
        vm.prank(owner_);
        (bool ok, bytes memory data) =
            address(account).call(
                abi.encodeCall(
                    account.upgradeToAndCall,
                    (
                        address(next),
                        abi.encodeCall(account.initializeAccount, (abi.encode(address(0))))
                    )
                )
            );
        _assertRevert(ok, data, StandaloneSingleOwnerHCA.OwnerCannotBeZero.selector);
        assert(_implementationOf(address(account)) == address(implementation));
        assert(vm.load(address(account), slot) == oldLegacy);
        _assertState(owner_, nonce);
    }

    function check_revokingTargetApprovalBlocksUpgrade(address owner_, uint96 nonce) public {
        _seed(owner_, nonce);
        _approve();
        targetSet.set(address(next), false);
        vm.prank(owner_);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.upgradeToAndCall, (address(next), "")));
        _assertRevert(ok, data, StandaloneSingleOwnerHCA.UpgradeTargetNotApproved.selector);
        assert(_implementationOf(address(account)) == address(implementation));
        _assertState(owner_, nonce);
    }

    function check_revokingPredecessorApprovalBlocksUpgrade(address owner_, uint96 nonce) public {
        _seed(owner_, nonce);
        _approve();
        predecessorSet.set(address(implementation), false);
        vm.prank(owner_);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.upgradeToAndCall, (address(next), "")));
        _assertRevert(ok, data, IUUPSProxy.InvalidUpgradeTarget.selector);
        assert(_implementationOf(address(account)) == address(implementation));
        _assertState(owner_, nonce);
    }

    function check_zeroTargetRejected(address caller, uint96 nonce) public {
        _seed(INITIAL_OWNER, nonce);
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.upgradeToAndCall, (address(0), "")));
        _assertRevert(ok, data, IUUPSProxy.ImplementationCannotBeZeroAddress.selector);
        assert(_implementationOf(address(account)) == address(implementation));
        _assertState(INITIAL_OWNER, nonce);
    }

    function check_initialImplementationRejectsEveryPredecessor(address owner_, uint96 nonce)
        public
    {
        _seed(owner_, nonce);
        StandaloneSingleOwnerHCA initial =
            _implementation(IStandaloneHCAFactory(address(0)), IAddressSet(address(0)));
        targetSet.set(address(initial), true);
        vm.prank(owner_);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.upgradeToAndCall, (address(initial), "")));
        _assertRevert(ok, data, IUUPSProxy.InvalidUpgradeTarget.selector);
        assert(_implementationOf(address(account)) == address(implementation));
        _assertState(owner_, nonce);
    }

    function check_approvedTargetCannotUpgradeImplementationDirectly(address caller) public {
        _approve();
        vm.prank(caller);
        (bool ok, bytes memory data) =
            address(implementation).call(
                abi.encodeCall(account.upgradeToAndCall, (address(next), ""))
            );
        _assertRevert(ok, data, CallContextChecker.UnauthorizedCallContext.selector);
        assert(implementation.owner() == address(0));
    }

    function check_ownerBatchCannotHideUpgrade(address owner_, uint96 nonce) public {
        _seed(owner_, nonce);
        _approve();
        Execution[] memory calls = new Execution[](1);
        calls[0] = Execution(
            address(account),
            0,
            abi.encodeCall(account.upgradeToAndCall, (address(next), ""))
        );
        vm.prank(owner_);
        (bool ok, bytes memory data) =
            address(account).call(abi.encodeCall(account.executeByOwner, (calls)));
        _assertRevert(
            ok,
            data,
            owner_ == address(account)
                ? IUUPSProxy.UpgradeNotAllowedInContext.selector
                : StandaloneSingleOwnerHCA.CallerNotOwner.selector
        );
        assert(_implementationOf(address(account)) == address(implementation));
        _assertState(owner_, nonce);
    }

    function check_forwardApprovalDoesNotAuthorizeReverseUpgrade(address owner_, uint96 nonce)
        public
    {
        _seed(owner_, nonce);
        _approve();
        vm.prank(owner_);
        (bool forward, ) =
            address(account).call(abi.encodeCall(account.upgradeToAndCall, (address(next), "")));
        assert(forward);
        vm.prank(owner_);
        (bool reverse, bytes memory data) =
            address(account).call(
                abi.encodeCall(account.upgradeToAndCall, (address(implementation), ""))
            );
        _assertRevert(reverse, data, IUUPSProxy.InvalidUpgradeTarget.selector);
        assert(_implementationOf(address(account)) == address(next));
        _assertState(owner_, nonce);
    }

    function _approve() internal {
        targetSet.set(address(next), true);
        predecessorSet.set(address(implementation), true);
    }
}
