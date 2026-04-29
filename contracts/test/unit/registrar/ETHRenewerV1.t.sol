// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test, console} from "forge-std/Test.sol";
import {
    INameWrapper,
    CANNOT_APPROVE,
    CANNOT_TRANSFER,
    CANNOT_UNWRAP,
    CAN_DO_EVERYTHING
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IPriceOracle} from "@ens/contracts/ethregistrar/IPriceOracle.sol";
import {
    MigrationControllerFixture,
    RegistryRolesLib,
    IRegistry
} from "~test/unit/migration/MigrationControllerFixture.sol";
import {
    ETHRenewerV1,
    IWrappedETHRegistrarController,
    IPermissionedRegistry,
    NameCoder
} from "~src/registrar/ETHRenewerV1.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

// [gas analysis]
// * Juggle: 35494
// * Unwrapped: 43133
// * Wrapped: 96128

contract ETHRenewerV1Test is MigrationControllerFixture {
    MockWrappedETHRegistrarController wrappedController;
    ETHRenewerV1 renewer;

    string labelUnwrapped = "unwrapped";
    string labelUnlocked = "unlocked";
    string labelLocked = "locked";
    string labelCannotTransfer = "cannot-transfer";
    string labelFrozenApproval = "frozen-approval";

    function setUp() public override {
        super.setUp();

        wrappedController = new MockWrappedETHRegistrarController(nameWrapper);
        renewer = new ETHRenewerV1(nameWrapper, address(wrappedController), ethRegistry);

        // enable _extendReservation()
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_RENEW, address(this));

        // register v1 migration cases (before registrar is disabled)
        registerUnwrapped(labelUnwrapped);
        testDuration += testDuration;
        registerWrappedETH2LD(labelUnlocked, CAN_DO_EVERYTHING);
        testDuration += testDuration;
        registerWrappedETH2LD(labelLocked, CANNOT_UNWRAP);
        testDuration += testDuration;
        registerWrappedETH2LD(labelCannotTransfer, CANNOT_UNWRAP | CANNOT_TRANSFER);
        testDuration += testDuration;
        {
            bytes memory name = registerWrappedETH2LD(labelFrozenApproval, CANNOT_UNWRAP);
            bytes32 node = NameCoder.namehash(name, 0);
            vm.prank(user);
            nameWrapper.approve(address(1), uint256(node));
            vm.prank(user);
            nameWrapper.setFuses(node, uint16(CANNOT_APPROVE));
        }

        nameWrapper.setController(ensV1Controller, false); // remove default controller
        nameWrapper.setController(address(wrappedController), true); // add mock wrapped controller
        nameWrapper.renounceOwnership(); // lock it

        ethRegistrarV1.removeController(ensV1Controller); // remove default controller
        ethRegistrarV1.addController(address(renewer)); // add renewer
        ethRegistrarV1.transferOwnership(address(renewer)); // transfer to renewer

        // check state
        assertEq(nameWrapper.owner(), address(0), "NameWrapper locked");
        assertFalse(nameWrapper.controllers(ensV1Controller), "NameWrapper og controller");
        assertFalse(ethRegistrarV1.controllers(ensV1Controller), "BaseRegistrar og controller");
        assertEq(ethRegistrarV1.owner(), address(renewer), "Renewer owns BaseRegistrar");
        assertTrue(
            ethRegistrarV1.controllers(address(renewer)),
            "Renewer is BaseRegistrar controller"
        );

        // BaseRegistrar.owner = renewer
        // BaseRegistrar.controllers = [graveyard, renewer]
        // NameWrapper.controllers = [wrappedController]
    }

    function test_constructor() external view {
        assertEq(address(renewer.NAME_WRAPPER()), address(nameWrapper), "NAME_WRAPPER");
        assertEq(
            address(renewer.WRAPPED_CONTROLLER()),
            address(wrappedController),
            "WRAPPED_CONTROLLER"
        );
        assertEq(address(renewer.ETH_REGISTRY()), address(ethRegistry), "ETH_REGISTRY");
        assertEq(renewer.GRACE_PERIOD(), gracePeriodV1, "GRACE_PERIOD");
    }

    function test_sync_unregistered() external {
        uint256 tokenIdV1 = LibLabel.id(testLabel);
        assertTrue(ethRegistrarV1.available(tokenIdV1));

        assertEq(ethRegistrarV1.nameExpires(tokenIdV1), 0, "v1");
        assertEq(ethRegistry.getExpiry(tokenIdV1), 0, "v2");

        _expectSync(testLabel, false);
    }

    function test_sync_migrated() external {
        // register in v2
        ethRegistry.register(
            testLabel,
            address(user),
            IRegistry(address(0)),
            address(0),
            0,
            _soon()
        );

        _expectSync(testLabel, false);
    }

    function test_sync_expired() external {
        uint256 tokenIdV1 = LibLabel.id(labelUnwrapped);
        uint64 expired = uint64(ethRegistrarV1.nameExpires(tokenIdV1)) + gracePeriodV1 + 1;
        ethRegistry.renew(tokenIdV1, expired + 1);

        // "forgot to sync" => reserved in v2 but fully expired in v1
        vm.warp(expired);
        assertTrue(ethRegistrarV1.available(tokenIdV1), "v1");
        assertEq(
            uint8(ethRegistry.getStatus(tokenIdV1)),
            uint8(IPermissionedRegistry.Status.RESERVED),
            "v2"
        );

        _expectSync(labelUnwrapped, false);
    }

    function test_sync_unwrapped(uint64 grace, bool extend) external {
        if (grace > 0) _warpToGrace(labelUnwrapped);
        if (extend) _extendReservation(labelUnwrapped);
        _expectSync(labelUnwrapped, extend);
    }

    function test_sync_unlocked(bool grace, bool extend) external {
        if (grace) _warpToGrace(labelUnlocked);
        if (extend) _extendReservation(labelUnlocked);
        _expectSync(labelUnlocked, extend);
    }

    function test_sync_locked(bool grace, bool extend) external {
        if (grace) _warpToGrace(labelLocked);
        if (extend) _extendReservation(labelLocked);
        _expectSync(labelLocked, extend);
    }

    function test_sync_cannotTransfer(bool grace, bool extend) external {
        if (grace) _warpToGrace(labelCannotTransfer);
        if (extend) _extendReservation(labelCannotTransfer);
        _expectSync(labelCannotTransfer, extend);
    }

    function test_sync_frozenApproval(bool grace, bool extend) external {
        if (grace) _warpToGrace(labelFrozenApproval);
        if (extend) _extendReservation(labelFrozenApproval);
        _expectSync(labelFrozenApproval, extend);
    }

    function test_sync_batch(uint256) external {
        string[] memory labels = new string[](5);
        uint256 n;
        if (vm.randomBool()) labels[n++] = labelUnwrapped;
        if (vm.randomBool()) labels[n++] = labelUnlocked;
        if (vm.randomBool()) labels[n++] = labelLocked;
        if (vm.randomBool()) labels[n++] = labelCannotTransfer;
        if (vm.randomBool()) labels[n++] = labelFrozenApproval;
        assembly {
            mstore(labels, n) // truncate
        }

        State[] memory states = new State[](labels.length);
        for (uint256 i; i < labels.length; ++i) {
            string memory label = labels[i];
            bool extend = vm.randomBool();
            if (extend) _extendReservation(label);
            assertEq(renewer.canSync(label), extend);
            states[i] = _getState(label);
        }

        renewer.sync(labels);

        for (uint256 i; i < labels.length; ++i) {
            _expectSynced(states[i]);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Gas
    ////////////////////////////////////////////////////////////////////////

    function test_gas_juggle() external {
        vm.startPrank(address(renewer));
        uint256 g = gasleft();
        ethRegistrarV1.addController(address(wrappedController));
        ethRegistrarV1.removeController(address(wrappedController));
        g -= gasleft();
        vm.stopPrank();
        console.log("Gas: %s", g);
    }

    function test_gas_sync_unwrapped() external {
        _extendReservation(labelUnwrapped);
        string[] memory labels = new string[](1);
        labels[0] = labelUnwrapped;
        uint256 g = gasleft();
        renewer.sync(labels);
        g -= gasleft();
        console.log("Gas: %s", g);
    }

    function test_gas_sync_wrapped() external {
        _extendReservation(labelUnlocked);
        string[] memory labels = new string[](1);
        labels[0] = labelUnlocked;
        uint256 g = gasleft();
        renewer.sync(labels);
        g -= gasleft();
        console.log("Gas: %s", g);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    struct State {
        string label;
        uint64 expiryV1;
        uint64 expiryV2;
        uint64 syncDuration;
        bool syncWrapper;
    }

    function _warpToGrace(string memory label) internal {
        uint256 tokenIdV1 = LibLabel.id(label);
        vm.warp(ethRegistrarV1.nameExpires(tokenIdV1) + vm.randomUint(0, gracePeriodV1 - 1));
        vm.expectRevert();
        ethRegistrarV1.ownerOf(tokenIdV1);
        assertFalse(ethRegistrarV1.available(tokenIdV1), "grace:available");
    }

    function _extendReservation(string memory label) internal {
        uint256 tokenIdV1 = LibLabel.id(label);
        IPermissionedRegistry.State memory state = ethRegistry.getState(tokenIdV1);
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.RESERVED), "reserved");
        ethRegistry.renew(tokenIdV1, state.expiry + uint64(vm.randomUint(1, 1000 days)));
    }

    function _getState(string memory label) internal view returns (State memory state) {
        state.label = label;
        uint256 tokenIdV1 = LibLabel.id(label);
        state.expiryV1 = uint64(ethRegistrarV1.nameExpires(tokenIdV1));
        state.expiryV2 = ethRegistry.getExpiry(tokenIdV1);
        (state.syncDuration, state.syncWrapper) = renewer.getState(tokenIdV1);
    }

    function _expectSynced(State memory state0) internal view {
        State memory state1 = _getState(state0.label);
        assertEq(state0.expiryV1 + state0.syncDuration, state1.expiryV1, "synced:expiryV1");
        if (state0.syncDuration > 0) {
            assertEq(
                state1.expiryV1 + premigrationBonusDuration,
                state1.expiryV2,
                "synced:expiryV2"
            );
        }
        if (state0.syncWrapper) {
            bytes32 node = NameCoder.namehash(NameCoder.ETH_NODE, keccak256(bytes(state0.label)));
            (, , uint64 wrappedExpiry) = nameWrapper.getData(uint256(node));
            assertEq(wrappedExpiry, state1.expiryV1 + gracePeriodV1, "synced:wrapper");
        }
    }

    function _expectSync(string memory label, bool expect) internal {
        assertEq(renewer.canSync(label), expect, "canSync");
        State memory state = _getState(label);
        string[] memory labels = new string[](1);
        labels[0] = label;
        renewer.sync(labels);
        _expectSynced(state);
    }
}

// https://github.com/ensdomains/ens-contracts/blob/staging/deployments/mainnet/WrappedETHRegistrarController.json
contract MockWrappedETHRegistrarController {
    INameWrapper internal immutable NAME_WRAPPER;
    constructor(INameWrapper nameWrapper) {
        NAME_WRAPPER = nameWrapper;
    }
    function renew(string calldata label, uint256 duration) external payable {
        require(duration == 0);
        NAME_WRAPPER.renew(LibLabel.id(label), duration);
    }
}
