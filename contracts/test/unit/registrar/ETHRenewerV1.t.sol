// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";
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
    NameCoder,
    LibMigration
} from "~src/registrar/ETHRenewerV1.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";

contract ETHRenewerV1Test is MigrationControllerFixture {
    MockWrappedETHRegistrarController wrappedController;
    ETHRenewerV1 renewer;
    uint64 cutoffExpiry;
    uint64 afterCutoff;

    string labelUnwrapped = "unwrapped";
    string labelUnlocked = "unlocked";
    string labelLocked = "locked";
    string labelCannotTransfer = "cannot-transfer";
    string labelFrozenApproval = "frozen-approval";

    function setUp() public override {
        super.setUp();

        // enable _extendReservation()
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_RENEW, address(this));

        // register v1 migration cases (before registrar is disabled)
        registerUnwrapped(labelUnwrapped);
        registerWrappedETH2LD(labelUnlocked, CAN_DO_EVERYTHING);
        registerWrappedETH2LD(labelLocked, CANNOT_UNWRAP);
        registerWrappedETH2LD(labelCannotTransfer, CANNOT_UNWRAP | CANNOT_TRANSFER);
        {
            bytes memory name = registerWrappedETH2LD(labelFrozenApproval, CANNOT_UNWRAP);
            bytes32 node = NameCoder.namehash(name, 0);
            vm.prank(user);
            nameWrapper.approve(address(1), uint256(node));
            vm.prank(user);
            nameWrapper.setFuses(node, uint16(CANNOT_APPROVE));
        }

        cutoffExpiry = uint64(block.timestamp) + testDuration + gracePeriodV1 + 1 days; // after launch (arbitrary duration)
        afterCutoff = cutoffExpiry + 1 days; // (arbitrary duration)

        wrappedController = new MockWrappedETHRegistrarController(nameWrapper);
        renewer = new ETHRenewerV1(
            nameWrapper,
            address(wrappedController),
            ethRegistry,
            cutoffExpiry
        );

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

        // BaseRegistrar.controllers = [renewer]
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
        assertEq(renewer.CUTOFF_EXPIRY(), cutoffExpiry, "CUTOFF_EXPIRY");
    }

    function test_sync_unregistered() external {
        assertEq(ethRegistrarV1.nameExpires(LibLabel.id(testLabel)), 0, "v1");
        assertEq(ethRegistry.getExpiry(LibLabel.id(testLabel)), 0, "v2");

        assertFalse(renewer.canSync(testLabel));
        renewer.sync(_one(testLabel)); // noop
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

        // try to sync it
        assertFalse(renewer.canSync(testLabel));
        renewer.sync(_one(testLabel)); // noop
    }

    function test_sync_expiredAfterGrace() external {
        vm.warp(ethRegistrarV1.nameExpires(LibLabel.id(labelUnwrapped)) + gracePeriodV1);
        vm.expectRevert();
        ethRegistrarV1.ownerOf(LibLabel.id(labelUnwrapped));

        assertFalse(renewer.canSync(labelUnwrapped));
        renewer.sync(_one(labelUnwrapped)); // noop
    }

    function test_sync_unwrapped_beforeCutoff(bool grace) external {
        if (grace) {
            _warpToGrace(labelUnwrapped);
        }
        _extendReservation(labelUnwrapped);
        _checkSync(labelUnwrapped, true);
    }

    function test_sync_unwrapped_afterCutoff() external {
        ethRegistry.renew(LibLabel.id(labelUnwrapped), afterCutoff);
        _checkSync(labelUnwrapped, true);

        assertEq(ethRegistrarV1.nameExpires(LibLabel.id(labelUnwrapped)), cutoffExpiry); // cutoff

        assertFalse(renewer.canSync(labelUnwrapped));
        renewer.sync(_one(labelUnwrapped)); // noop
    }

    function test_sync_unlocked_beforeCutoff(bool grace) external {
        if (grace) {
            _warpToGrace(labelUnlocked);
        }
        _extendReservation(labelUnlocked);
        _checkSync(labelUnlocked, true);
    }

    function test_sync_unlocked_afterCutoff() external {
        ethRegistry.renew(LibLabel.id(labelUnlocked), afterCutoff);
        _checkSync(labelUnlocked, true);

        (, , uint64 wrappedExpiry) = nameWrapper.getData(
            uint256(NameCoder.namehash(NameCoder.ETH_NODE, keccak256(bytes(labelUnlocked))))
        );
        assertEq(wrappedExpiry, cutoffExpiry + gracePeriodV1); // cutoff

        assertFalse(renewer.canSync(labelUnlocked));
        renewer.sync(_one(labelUnlocked)); // noop
    }

    function test_sync_locked_beforeCutoff(bool grace) external {
        if (grace) {
            _warpToGrace(labelLocked);
        }
        _extendReservation(labelLocked);
        _checkSync(labelLocked, true);
    }

    function test_sync_locked_afterCutoff() external {
        ethRegistry.renew(LibLabel.id(labelLocked), afterCutoff);
        _checkSync(labelLocked, true);

        (, , uint64 wrappedExpiry) = nameWrapper.getData(
            uint256(NameCoder.namehash(NameCoder.ETH_NODE, keccak256(bytes(labelLocked))))
        );
        assertEq(wrappedExpiry, cutoffExpiry + gracePeriodV1); // cutoff

        assertFalse(renewer.canSync(labelLocked));
        renewer.sync(_one(labelLocked)); // noop
    }

    function test_sync_cannotTransfer_beforeCutoff(bool grace) external {
        if (grace) {
            _warpToGrace(labelCannotTransfer);
        }
        _extendReservation(labelCannotTransfer);
        _checkSync(labelCannotTransfer, false);
    }

    function test_sync_cannotTransfer_afterCutoff(bool grace) external {
        ethRegistry.renew(LibLabel.id(labelCannotTransfer), afterCutoff);
        _checkSync(labelCannotTransfer, false);

        _extendReservation(labelCannotTransfer);
        if (grace) {
            _warpToGrace(labelCannotTransfer);
        }
        _checkSync(labelCannotTransfer, false);
    }

    function test_sync_frozenApproval_beforeCutoff(bool grace) external {
        if (grace) {
            _warpToGrace(labelFrozenApproval);
        }
        _extendReservation(labelFrozenApproval);
        _checkSync(labelFrozenApproval, false);
    }

    function test_sync_frozenApproval_afterCutoff(bool grace) external {
        ethRegistry.renew(LibLabel.id(labelFrozenApproval), afterCutoff);
        _checkSync(labelFrozenApproval, false);

        _extendReservation(labelFrozenApproval);
        if (grace) {
            _warpToGrace(labelFrozenApproval);
        }
        _checkSync(labelFrozenApproval, false);
    }

    function test_sync_none() external {
        renewer.sync(new string[](0));
    }

    function test_sync_multiple() external {
        string[] memory v = new string[](3);
        v[0] = labelUnwrapped;
        v[1] = labelUnlocked;
        v[2] = labelLocked;

        for (uint256 i; i < v.length; ++i) {
            _extendReservation(v[i]);
            assertTrue(renewer.canSync(v[i]));
        }

        renewer.sync(v);

        for (uint256 i; i < v.length; ++i) {
            _checkSynced(v[i], true);
        }
    }

    function test_sync_mixed() external {
        string[] memory v = new string[](2);
        v[0] = labelUnwrapped;
        v[1] = labelFrozenApproval;

        ethRegistry.renew(LibLabel.id(v[0]), afterCutoff);
        ethRegistry.renew(LibLabel.id(v[1]), afterCutoff);
        renewer.sync(v);

        _extendReservation(v[0]);
        _extendReservation(v[1]);

        assertFalse(renewer.canSync(v[0]));
        assertTrue(renewer.canSync(v[1]));

        renewer.sync(v);

        _checkSynced(v[0], true);
        _checkSynced(v[1], false);
    }

    /// @dev Warp to sometime during grace period.
    function _warpToGrace(string memory label) internal {
        vm.warp(ethRegistrarV1.nameExpires(LibLabel.id(label)) + vm.randomUint(1, gracePeriodV1));
        vm.expectRevert();
        ethRegistrarV1.ownerOf(LibLabel.id(label));
    }

    function _extendReservation(string memory label) internal {
        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id(label));
        require(
            state.status == IPermissionedRegistry.Status.RESERVED ||
                (state.status == IPermissionedRegistry.Status.AVAILABLE &&
                    uint32(state.tokenId) == 0 &&
                    block.timestamp - state.expiry < gracePeriodV1),
            "reserved w/grace"
        );
        ethRegistry.renew(LibLabel.id(label), state.expiry + gracePeriodV1);
    }

    function _checkSync(string memory label, bool isMigratable) internal {
        assertTrue(renewer.canSync(label), "canSync");
        renewer.sync(_one(label));
        _checkSynced(label, isMigratable);
    }

    function _checkSynced(string memory label, bool isMigratable) internal view {
        uint256 labelId = LibLabel.id(label);
        uint64 expiryV1 = uint64(ethRegistrarV1.nameExpires(labelId));
        uint64 expiryV2 = ethRegistry.getExpiry(labelId);
        if (expiryV2 > cutoffExpiry && isMigratable) {
            expiryV2 = cutoffExpiry;
        }
        assertEq(expiryV1, expiryV2, "unwrappedSync");
        bytes32 node = NameCoder.namehash(NameCoder.ETH_NODE, bytes32(labelId));
        if (nameWrapper.isWrapped(node)) {
            (, , uint64 wrappedExpiry) = nameWrapper.getData(uint256(node));
            assertEq(wrappedExpiry, expiryV2 + gracePeriodV1, "wrappedSync");
        }
    }

    function _one(string memory label) internal pure returns (string[] memory v) {
        v = new string[](1);
        v[0] = label;
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
