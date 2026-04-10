// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {console} from "forge-std/console.sol";
import {
    CAN_DO_EVERYTHING,
    CANNOT_UNWRAP,
    PARENT_CANNOT_CONTROL
} from "@ens/contracts/wrapper/INameWrapper.sol";

import {MigrationControllerFixture, NameCoder} from "./MigrationControllerFixture.sol";

contract GraveyardTest is MigrationControllerFixture {
    uint256 constant N = 10;

    function setUp() public override {
        super.setUp();
        ethRegistrarV1.addController(address(graveyard));
    }

    function test_clear_deep() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped(testLabel);

        for (uint256 i; i < N; ++i) {
            vm.prank(user);
            registryV1.setSubnodeRecord(
                NameCoder.namehash(name, 0),
                keccak256(bytes(testLabel)),
                user,
                address(1),
                0
            );
            name = NameCoder.addLabel(name, testLabel);
        }

        _simulateUnwrappedMigration(tokenId);

        graveyard.clear(_oneName(name));
    }

    function test_clear_wide() external {
        bytes[] memory names = new bytes[](10);

        for (uint256 i; i < names.length; ++i) {
            (bytes memory name, uint256 tokenId) = registerUnwrapped(_label(i));
            vm.prank(user);
            registryV1.setSubnodeRecord(
                NameCoder.namehash(name, 0),
                keccak256(bytes(testLabel)),
                friend,
                address(1),
                0
            );
            _simulateUnwrappedMigration(tokenId);
            names[i] = NameCoder.addLabel(name, testLabel);
        }

        graveyard.clear(names);

        for (uint256 i; i < names.length; ++i) {
            assertEq(registryV1.resolver(NameCoder.namehash(names[i], 0)), address(0));
        }
    }

    function test_clear_nestedLocked_migrateBoth() external {
        bytes memory name2 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(
            name2,
            testLabel,
            user,
            PARENT_CANNOT_CONTROL | CANNOT_UNWRAP
        );

        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name2, 0), address(1));
        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));

        _simulateLockedMigration(name2);

        vm.expectRevert();
        graveyard.clear(_oneName(name3));

        _simulateLockedMigration(name3);

        graveyard.clear(_oneName(name3));

        assertEq(registryV1.resolver(NameCoder.namehash(name2, 0)), address(0));
        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0));
    }

    function test_clear_nestedLocked_migrateParent_expiredChild() external {
        bytes memory name2 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(
            name2,
            testLabel,
            user,
            PARENT_CANNOT_CONTROL | CANNOT_UNWRAP
        );

        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name2, 0), address(1));
        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));

        _simulateLockedMigration(name2);

        vm.expectRevert();
        graveyard.clear(_oneName(name3));

        _simulateExpiry(name3);

        graveyard.clear(_oneName(name3));

        assertEq(registryV1.resolver(NameCoder.namehash(name2, 0)), address(0));
        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0));
    }

    function test_clear_nestedLocked_bothExpired() external {
        bytes memory name2 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(
            name2,
            testLabel,
            user,
            PARENT_CANNOT_CONTROL | CANNOT_UNWRAP
        );

        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name2, 0), address(1));
        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));

        // expiry(name2) > expiry(name3)
        vm.prank(ensV1Controller);
        nameWrapper.renew(uint256(keccak256(bytes(testLabel))), 10 days);

        vm.expectRevert();
        graveyard.clear(_oneName(name3));

        _simulateExpiry(name3);

        vm.expectRevert();
        graveyard.clear(_oneName(name3));

        _simulateExpiry(name2);

        graveyard.clear(_oneName(name3));

        assertEq(registryV1.resolver(NameCoder.namehash(name2, 0)), address(0));
        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0));
    }

    function test_clear_locked_expired() external {
        bytes memory name0 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes memory name = name0;
        for (uint256 i; i < N; ++i) {
            name = createWrappedChild(name, testLabel, user, PARENT_CANNOT_CONTROL | CANNOT_UNWRAP);
            vm.prank(user);
            nameWrapper.setResolver(NameCoder.namehash(name, 0), address(1));
        }

        vm.expectRevert();
        graveyard.clear(_oneName(name));

        _simulateExpiry(name0);

        graveyard.clear(_oneName(name));

        name = name0;
        for (uint256 i; i < N; ++i) {
            name = NameCoder.addLabel(name, testLabel);
            assertEq(registryV1.resolver(NameCoder.namehash(name, 0)), address(0));
        }
    }

    function test_clear_complex() external {
        bytes memory name2 = registerWrappedETH2LD("2", CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(name2, "3", user, CAN_DO_EVERYTHING);
        bytes memory name4 = createWrappedChild(name3, "4", user, CAN_DO_EVERYTHING);

        // name2 resolver would be cleared by migration

        // set resolvers
        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(3));
        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name4, 0), address(4));

        // unwrap name4
        vm.prank(user);
        nameWrapper.unwrap(
            NameCoder.namehash(name3, 0),
            keccak256(bytes(NameCoder.firstLabel(name4))),
            address(graveyard)
        );

        // name2 = wrapped locked
        // name3 = wrapped unlocked emancipated
        // name4 = unwrapped

        _simulateLockedMigration(name2);
        _simulateLockedMigration(name3);

        graveyard.clear(_oneName(name4));

        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0), "3");
        assertEq(registryV1.resolver(NameCoder.namehash(name4, 0)), address(0), "4");
    }

    function _simulateUnwrappedMigration(uint256 tokenId) internal {
        vm.prank(user);
        registryV1.setRecord(
            NameCoder.namehash(NameCoder.ETH_NODE, bytes32(tokenId)),
            address(graveyard), // owner
            address(0), // resolver
            0 // ttl
        );
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(user, address(graveyard), tokenId);
    }

    function _simulateLockedMigration(bytes memory name) internal {
        bytes32 node = NameCoder.namehash(name, 0);
        vm.prank(user);
        nameWrapper.setResolver(node, address(0));
        vm.prank(user);
        nameWrapper.safeTransferFrom(user, address(graveyard), uint256(node), 1, "");
    }

    function _simulateExpiry(bytes memory name) internal {
        (bytes32 labelHash, uint256 offset) = NameCoder.readLabel(name, 0);
        if (NameCoder.namehash(name, offset) == NameCoder.ETH_NODE) {
            vm.warp(
                ethRegistrarV1.nameExpires(uint256(labelHash)) + ethRegistrarV1.GRACE_PERIOD() + 1
            );
        } else {
            (address owner, , uint64 expiry) = nameWrapper.getData(
                uint256(NameCoder.namehash(name, 0))
            );
            if (owner != address(0)) {
                vm.warp(expiry + 1);
            }
        }
    }

    function _oneName(bytes memory name) internal pure returns (bytes[] memory names) {
        names = new bytes[](1);
        names[0] = name;
    }
}
