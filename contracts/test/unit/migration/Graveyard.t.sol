// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    CAN_DO_EVERYTHING,
    CANNOT_SET_RESOLVER,
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

    function test_clear_root() external {
        graveyard.clear(_oneName(NameCoder.encode(""))); // noop
    }

    function test_clear_eth() external {
        graveyard.clear(_oneName(NameCoder.encode("eth"))); // noop
    }

    function test_clear_xyz() external {
        vm.expectRevert();
        graveyard.clear(_oneName(NameCoder.encode("xyz")));
        vm.expectRevert();
        graveyard.clear(_oneName(NameCoder.encode("test.xyz")));
    }

    function test_clear_registered_unwrapped() external {
        (bytes memory name, ) = registerUnwrapped(testLabel);

        vm.expectRevert();
        graveyard.clear(_oneName(name));
    }

    function test_clear_registered_unlocked() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);

        vm.expectRevert();
        graveyard.clear(_oneName(name));
    }

    function test_clear_registered_locked() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);

        vm.expectRevert();
        graveyard.clear(_oneName(name));
    }

    function test_clear_unregistered(uint256) external {
        graveyard.clear(_oneName(_randomName()));
    }

    function test_clear_junk_deep(uint256) external {
        bytes memory name = _randomName();
        bytes32 node = NameCoder.namehash(name, 0);

        _claimNodes(name, 0, address(user));
        vm.prank(user);
        registryV1.setResolver(node, address(1));
        assertEq(registryV1.resolver(node), address(1));

        graveyard.clear(_oneName(name));

        assertEq(registryV1.resolver(node), address(0));
    }

    function test_clear_deep() external {
        (bytes memory name0, ) = registerUnwrapped(testLabel);

        bytes memory name = name0;
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

        _simulateMigration(name0);

        graveyard.clear(_oneName(name));

        name = name0;
        for (uint256 i; i < N; ++i) {
            name = NameCoder.addLabel(name, testLabel);
            assertEq(registryV1.resolver(NameCoder.namehash(name, 0)), address(0), vm.toString(i));
        }
    }

    function test_clear_wide() external {
        bytes[] memory names = new bytes[](N);

        for (uint256 i; i < names.length; ++i) {
            (bytes memory name, ) = registerUnwrapped(_label(i));
            vm.prank(user);
            registryV1.setSubnodeRecord(
                NameCoder.namehash(name, 0),
                keccak256(bytes(testLabel)),
                friend,
                address(1),
                0
            );
            _simulateMigration(name);
            names[i] = NameCoder.addLabel(name, testLabel);
        }

        graveyard.clear(names);

        for (uint256 i; i < names.length; ++i) {
            assertEq(
                registryV1.resolver(NameCoder.namehash(names[i], 0)),
                address(0),
                vm.toString(i)
            );
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

        // set resolvers
        vm.startPrank(user);
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));
        vm.stopPrank();

        _simulateMigration(name2);

        vm.expectRevert();
        graveyard.clear(_oneName(name3));

        _simulateMigration(name3);

        graveyard.clear(_oneName(name3));

        assertEq(registryV1.resolver(NameCoder.namehash(name2, 0)), address(0), "2");
        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0), "3");
    }

    function test_clear_nestedLocked_migrateParent_expiredChild() external {
        bytes memory name2 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(
            name2,
            testLabel,
            user,
            PARENT_CANNOT_CONTROL | CANNOT_UNWRAP
        );

        // set resolvers
        vm.startPrank(user);
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));
        vm.stopPrank();

        _simulateMigration(name2);

        vm.expectRevert();
        graveyard.clear(_oneName(name3));

        _simulateExpiry(name3);

        graveyard.clear(_oneName(name3));

        assertEq(registryV1.resolver(NameCoder.namehash(name2, 0)), address(0), "2");
        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0), "3");
    }

    function test_clear_nestedLocked_bothExpired() external {
        bytes memory name2 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(
            name2,
            testLabel,
            user,
            PARENT_CANNOT_CONTROL | CANNOT_UNWRAP
        );

        // set resolvers
        vm.startPrank(user);
        nameWrapper.setResolver(NameCoder.namehash(name2, 0), address(1));
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));
        vm.stopPrank();

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

        assertEq(registryV1.resolver(NameCoder.namehash(name2, 0)), address(0), "2");
        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0), "3");
    }

    function test_clear_detached(bool unwrapped) external {
        bytes memory name2 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(name2, testLabel, user, PARENT_CANNOT_CONTROL);

        // set resolvers
        vm.startPrank(user);
        nameWrapper.setResolver(NameCoder.namehash(name2, 0), address(1));
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));
        vm.stopPrank();

        if (unwrapped) {
            vm.prank(user);
            nameWrapper.unwrap(
                NameCoder.namehash(name2, 0),
                keccak256(bytes(NameCoder.firstLabel(name3))),
                address(graveyard)
            );
        }

        _simulateExpiry(name2);

        graveyard.clear(_oneName(name3));

        assertEq(registryV1.resolver(NameCoder.namehash(name2, 0)), address(0), "2");
        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0), "3");
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
            assertEq(registryV1.resolver(NameCoder.namehash(name, 0)), address(0), vm.toString(i));
        }
    }

    function test_clear_complex() external {
        bytes memory name2 = registerWrappedETH2LD("2", CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(name2, "3", user, PARENT_CANNOT_CONTROL);
        bytes memory name4 = createWrappedChild(name3, "4", user, CAN_DO_EVERYTHING);

        // set resolvers
        vm.startPrank(user);
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));
        nameWrapper.setResolver(NameCoder.namehash(name3, 0), address(1));
        nameWrapper.setResolver(NameCoder.namehash(name4, 0), address(1));
        vm.stopPrank();

        // unwrap name4
        vm.prank(user);
        nameWrapper.unwrap(
            NameCoder.namehash(name3, 0),
            keccak256(bytes(NameCoder.firstLabel(name4))),
            address(graveyard)
        );

        // name2 = locked
        // name3 = detached (wrapped unlocked emancipated)
        // name4 = unwrapped

        _simulateMigration(name2);
        _simulateMigration(name3);

        graveyard.clear(_oneName(name4));

        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0), "2");
        assertEq(registryV1.resolver(NameCoder.namehash(name3, 0)), address(0), "3");
        assertEq(registryV1.resolver(NameCoder.namehash(name4, 0)), address(0), "4");
    }

    /// @dev Clear resolver if possible and transfer to graveyard.
    function _simulateMigration(bytes memory name) internal {
        bytes32 node = NameCoder.namehash(name, 0);
        (bytes32 labelHash, uint256 offset) = NameCoder.readLabel(name, 0);
        bytes32 parentNode = NameCoder.namehash(name, offset);
        address owner = registryV1.owner(node);
        if (owner == address(nameWrapper)) {
            uint32 fuses;
            (owner, fuses, ) = nameWrapper.getData(uint256(node));
            if ((fuses & CANNOT_SET_RESOLVER) == 0) {
                vm.prank(owner);
                nameWrapper.setResolver(node, address(0));
            }
            if ((fuses & CANNOT_UNWRAP) == 0) {
                vm.prank(owner);
                nameWrapper.unwrap(parentNode, labelHash, address(graveyard));
            } else {
                vm.prank(owner);
                nameWrapper.safeTransferFrom(owner, address(graveyard), uint256(node), 1, "");
            }
        } else if (parentNode == NameCoder.ETH_NODE) {
            vm.prank(owner);
            registryV1.setRecord(
                node,
                address(graveyard), // owner
                address(0), // resolver
                0 // ttl
            );
            vm.prank(owner);
            ethRegistrarV1.safeTransferFrom(owner, address(graveyard), uint256(labelHash));
        }
    }

    /// @dev Warp past expiry + grace.
    function _simulateExpiry(bytes memory name) internal {
        (bytes32 labelHash, uint256 offset) = NameCoder.readLabel(name, 0);
        if (NameCoder.namehash(name, offset) == NameCoder.ETH_NODE) {
            vm.warp(ethRegistrarV1.nameExpires(uint256(labelHash)) + gracePeriodV1 + 1);
        } else {
            (address owner, , uint64 expiry) = nameWrapper.getData(
                uint256(NameCoder.namehash(name, 0))
            );
            if (owner != address(0)) {
                vm.warp(expiry + 1);
            }
        }
    }

    /// @dev Create random .eth name.
    function _randomName() internal returns (bytes memory name) {
        name = NameCoder.encode("eth");
        for (uint256 n = vm.randomUint(1, 10); n > 0; --n) {
            name = NameCoder.addLabel(name, new string(vm.randomUint(1, 255)));
        }
    }

    function _oneName(bytes memory name) internal pure returns (bytes[] memory names) {
        names = new bytes[](1);
        names[0] = name;
    }
}
