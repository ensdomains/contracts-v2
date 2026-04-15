// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {console} from "forge-std/console.sol";
import {CAN_DO_EVERYTHING, CANNOT_UNWRAP} from "@ens/contracts/wrapper/INameWrapper.sol";
import {
    UnlockedMigrationController,
    InvalidOwner
} from "~src/migration/UnlockedMigrationController.sol";
import {LockedMigrationController} from "~src/migration/LockedMigrationController.sol";
import {WrapperRegistry, RegistryRolesLib, LibMigration} from "~src/registry/WrapperRegistry.sol";
import {MigrationHelper} from "~src/migration/MigrationHelper.sol";
import {MigrationControllerFixture, NameCoder} from "./MigrationControllerFixture.sol";

contract MigrationHelperTest is MigrationControllerFixture {
    UnlockedMigrationController unlockedController;
    LockedMigrationController lockedController;
    WrapperRegistry wrapperRegistryImpl;
    MigrationHelper helper;

    address hacker = makeAddr("hacker");

    function setUp() public override {
        super.setUp();

        // unlocked
        unlockedController = new UnlockedMigrationController(nameWrapper, ethRegistry);
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, premigrationController);
        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(unlockedController)
        );

        // locked
        wrapperRegistryImpl = new WrapperRegistry(
            nameWrapper,
            verifiableFactory,
            address(ensV1Resolver),
            hcaFactory,
            metadata
        );
        lockedController = new LockedMigrationController(
            nameWrapper,
            ethRegistry,
            verifiableFactory,
            address(wrapperRegistryImpl)
        );
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, premigrationController);
        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(lockedController)
        );

        helper = new MigrationHelper(hcaFactory, unlockedController, lockedController);
    }

    function test_migrate_unwrapped_notApproved() external {
        (bytes memory name, ) = registerUnwrapped(testLabel);

        LibMigration.Data[] memory mds = new LibMigration.Data[](1);
        mds[0] = _unlockedData(name);

        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        helper.migrate(mds, _none(), _none());
    }

    function test_migrate_unlocked_notApproved() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);

        LibMigration.Data[] memory mds = new LibMigration.Data[](1);
        mds[0] = _unlockedData(name);

        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        helper.migrate(_none(), mds, _none());
    }

    function test_migrate_locked_notApproved() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);

        LibMigration.Data[] memory mds = new LibMigration.Data[](1);
        mds[0] = _lockedData(name);

        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        helper.migrate(_none(), _none(), mds);
    }

    function test_migrate_unwrapped_notOperator() external {
        (bytes memory name, ) = registerUnwrapped(testLabel);

        LibMigration.Data[] memory mds = new LibMigration.Data[](1);
        mds[0] = _unlockedData(name);

        vm.prank(user);
        ethRegistrarV1.setApprovalForAll(address(helper), true);

        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        vm.prank(hacker);
        helper.migrate(mds, _none(), _none());
    }

    function test_migrate_unlocked_notOperator() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);

        LibMigration.Data[] memory mds = new LibMigration.Data[](1);
        mds[0] = _unlockedData(name);

        vm.prank(user);
        nameWrapper.setApprovalForAll(address(helper), true);

        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        vm.prank(hacker);
        helper.migrate(_none(), mds, _none());
    }

    function test_migrate_locked_notOperator() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);

        LibMigration.Data[] memory mds = new LibMigration.Data[](1);
        mds[0] = _lockedData(name);

        vm.prank(user);
        nameWrapper.setApprovalForAll(address(helper), true);

        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        vm.prank(hacker);
        helper.migrate(_none(), _none(), mds);
    }

    function test_migrate_notSameOwner() external {
        bytes memory name1 = registerWrappedETH2LD("a", CAN_DO_EVERYTHING);
        vm.prank(friend);
        bytes memory name2 = this.registerWrappedETH2LD("b", CAN_DO_EVERYTHING);

        // user grants approval to helper
        vm.prank(user);
        nameWrapper.setApprovalForAll(address(helper), true);

        // friend grants approval to helper
        // (but is not sufficent, since different owner)
        vm.prank(friend);
        nameWrapper.setApprovalForAll(user, true);

        LibMigration.Data[] memory mds = new LibMigration.Data[](2);
        mds[0] = _unlockedData(name1);
        mds[1] = _unlockedData(name2);

        vm.expectRevert("ERC1155: caller is not owner nor approved");
        vm.prank(user);
        helper.migrate(_none(), mds, _none());

        // friend must grant approval to operator too
        vm.prank(friend);
        nameWrapper.setApprovalForAll(address(helper), true);

        vm.prank(user);
        helper.migrate(_none(), mds, _none());
    }

    function test_migrate_0unwrapped_0unlocked_0locked() external {
        _testMigrate(0, 0, 0);
    }
    function test_migrate_1unwrapped_0unlocked_0locked() external {
        _testMigrate(1, 0, 0);
    }
    function test_migrate_0unwrapped_1unlocked_0locked() external {
        _testMigrate(0, 1, 0);
    }
    function test_migrate_0unwrapped_0unlocked_1locked() external {
        _testMigrate(0, 0, 1);
    }
    function test_migrate_1unwrapped_1unlocked_1locked() external {
        _testMigrate(1, 1, 1);
    }
    function test_migrate_2unwrapped_2unlocked_2locked() external {
        _testMigrate(2, 2, 2);
    }
    function test_migrate_7unwrapped_8unlocked_9locked() external {
        _testMigrate(7, 8, 9);
    }

    function _testMigrate(uint256 numUnwrapped, uint256 numUnlocked, uint256 numLocked) public {
        LibMigration.Data[] memory unwrapped = new LibMigration.Data[](numUnwrapped);
        LibMigration.Data[] memory unlocked = new LibMigration.Data[](numUnlocked);
        LibMigration.Data[] memory locked = new LibMigration.Data[](numLocked);

        testLabel = "unwrapped";
        for (uint256 i; i < numUnwrapped; ++i) {
            (bytes memory name, ) = registerUnwrapped(_label(i));
            unwrapped[i] = _unlockedData(name);
        }
        testLabel = "unlocked";
        for (uint256 i; i < numUnlocked; ++i) {
            bytes memory name = registerWrappedETH2LD(_label(i), CAN_DO_EVERYTHING);
            unlocked[i] = _unlockedData(name);
        }
        testLabel = "locked";
        for (uint256 i; i < numLocked; ++i) {
            bytes memory name = registerWrappedETH2LD(_label(i), CANNOT_UNWRAP);
            locked[i] = _lockedData(name);
        }

        if (numUnwrapped > 0) {
            vm.prank(user);
            ethRegistrarV1.setApprovalForAll(address(helper), true);
        }
        if (numUnlocked > 0 || numLocked > 0) {
            vm.prank(user);
            nameWrapper.setApprovalForAll(address(helper), true);
        }

        vm.prank(user);
        helper.migrate(unwrapped, unlocked, locked);
    }

    function _none() internal pure returns (LibMigration.Data[] memory mds) {}
}
