// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file

import {Test, Vm} from "forge-std/Test.sol";

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {BatchRegistrar} from "~src/registrar/BatchRegistrar.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract BatchRegistrarTest is V2Fixture {
    BatchRegistrar batchRegistrar;

    address owner = address(this);
    address resolver = address(0xABCD);

    function setUp() external {
        deployV2Fixture();
        batchRegistrar = new BatchRegistrar(ethRegistry, owner);

        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(batchRegistrar)
        );
    }

    function test_batchRegister_new_names() public {
        string[] memory labels = new string[](3);
        uint64[] memory expires = new uint64[](3);

        labels[0] = "test1";
        expires[0] = uint64(block.timestamp + 86400);

        labels[1] = "test2";
        expires[1] = uint64(block.timestamp + 86400 * 2);

        labels[2] = "test3";
        expires[2] = uint64(block.timestamp + 86400 * 3);

        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        for (uint256 i = 0; i < labels.length; i++) {
            IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id(labels[i]));
            assertEq(
                uint256(state.status),
                uint256(IPermissionedRegistry.Status.RESERVED),
                "Status should be RESERVED"
            );
            assertEq(state.expiry, expires[i], "Expiry should match");
            assertEq(ethRegistry.getResolver(labels[i]), resolver, "Resolver should match");
        }
    }

    function test_batchRegister_renews_if_newer_expiry() public {
        uint64 originalExpiry = uint64(block.timestamp + 86400);
        string[] memory labels = new string[](1);
        uint64[] memory expires = new uint64[](1);
        labels[0] = "test";
        expires[0] = originalExpiry;
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("test"));
        assertEq(state.expiry, originalExpiry, "Initial expiry should match");

        uint64 newExpiry = uint64(block.timestamp + 86400 * 365);
        expires[0] = newExpiry;
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        state = ethRegistry.getState(LibLabel.id("test"));
        assertEq(state.expiry, newExpiry, "Expiry should be renewed");
    }

    function test_batchRegister_skips_if_same_or_older_expiry() public {
        uint64 originalExpiry = uint64(block.timestamp + 86400 * 365);
        string[] memory labels = new string[](1);
        uint64[] memory expires = new uint64[](1);
        labels[0] = "test";
        expires[0] = originalExpiry;
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("test"));
        assertEq(state.expiry, originalExpiry, "Initial expiry should match");

        uint64 earlierExpiry = uint64(block.timestamp + 86400);
        expires[0] = earlierExpiry;
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        state = ethRegistry.getState(LibLabel.id("test"));
        assertEq(state.expiry, originalExpiry, "Expiry should remain unchanged");
    }

    function test_batchRegister_mixed_new_and_existing() public {
        uint64 originalExpiry = uint64(block.timestamp + 86400);
        string[] memory labels = new string[](1);
        uint64[] memory expires = new uint64[](1);
        labels[0] = "existing";
        expires[0] = originalExpiry;
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        uint64 newExpiry = uint64(block.timestamp + 86400 * 365);
        string[] memory mixedLabels = new string[](3);
        uint64[] memory mixedExpires = new uint64[](3);

        mixedLabels[0] = "new1";
        mixedExpires[0] = newExpiry;

        mixedLabels[1] = "existing";
        mixedExpires[1] = newExpiry;

        mixedLabels[2] = "new2";
        mixedExpires[2] = newExpiry;

        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, mixedLabels, mixedExpires);

        IPermissionedRegistry.State memory state1 = ethRegistry.getState(LibLabel.id("new1"));
        assertEq(
            uint256(state1.status),
            uint256(IPermissionedRegistry.Status.RESERVED),
            "new1 should be RESERVED"
        );
        assertEq(state1.expiry, newExpiry, "new1 expiry should match");

        IPermissionedRegistry.State memory state2 = ethRegistry.getState(LibLabel.id("new2"));
        assertEq(
            uint256(state2.status),
            uint256(IPermissionedRegistry.Status.RESERVED),
            "new2 should be RESERVED"
        );
        assertEq(state2.expiry, newExpiry, "new2 expiry should match");

        IPermissionedRegistry.State memory existingState = ethRegistry.getState(
            LibLabel.id("existing")
        );
        assertEq(existingState.expiry, newExpiry, "existing expiry should be renewed");
    }

    function test_batchRegister_re_reserves_expired_names() public {
        uint64 originalExpiry = uint64(block.timestamp + 86400);
        string[] memory labels = new string[](1);
        uint64[] memory expires = new uint64[](1);
        labels[0] = "expiring";
        expires[0] = originalExpiry;
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        vm.warp(block.timestamp + 86401);

        uint64 newExpiry = uint64(block.timestamp + 86400 * 365);
        expires[0] = newExpiry;
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("expiring"));
        assertEq(
            uint256(state.status),
            uint256(IPermissionedRegistry.Status.RESERVED),
            "Should be re-reserved"
        );
        assertEq(state.expiry, newExpiry, "Expiry should match new expiry");
    }

    function test_batchRegister_empty_array() public {
        string[] memory labels = new string[](0);
        uint64[] memory expires = new uint64[](0);
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);
    }

    function test_batchRegister_single_name() public {
        string[] memory labels = new string[](1);
        uint64[] memory expires = new uint64[](1);
        labels[0] = "single";
        expires[0] = uint64(block.timestamp + 86400);

        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("single"));
        assertEq(
            uint256(state.status),
            uint256(IPermissionedRegistry.Status.RESERVED),
            "Status should be RESERVED"
        );
        assertEq(state.expiry, expires[0], "Expiry should match");
    }

    function test_batchRegister_onlyOwner() public {
        string[] memory labels = new string[](1);
        uint64[] memory expires = new uint64[](1);
        labels[0] = "test";
        expires[0] = uint64(block.timestamp + 86400);

        address unauthorized = address(0xBEEF);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized)
        );
        vm.prank(unauthorized);
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);
    }

    function test_batchRegister_duplicateLabelsInBatch() public {
        uint64 expiry1 = uint64(block.timestamp + 86400);
        uint64 expiry2 = uint64(block.timestamp + 86400 * 2);

        string[] memory labels = new string[](2);
        uint64[] memory expires = new uint64[](2);
        labels[0] = "duplicate";
        expires[0] = expiry1;
        labels[1] = "duplicate";
        expires[1] = expiry2;

        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("duplicate"));
        assertEq(
            uint256(state.status),
            uint256(IPermissionedRegistry.Status.RESERVED),
            "Status should be RESERVED"
        );
        assertEq(state.expiry, expiry2, "Expiry should be the renewed (second) value");
    }

    function test_batchRegister_events() public {
        uint64 expiry = uint64(block.timestamp + 86400);
        string[] memory labels = new string[](1);
        uint64[] memory expires = new uint64[](1);
        labels[0] = "eventtest";
        expires[0] = expiry;

        vm.recordLogs();
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 labelReservedSig = keccak256(
            "LabelReserved(uint256,bytes32,string,uint64,address)"
        );
        bool foundLabelReserved = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == labelReservedSig) {
                foundLabelReserved = true;
                bytes32 labelHash = keccak256(bytes("eventtest"));
                assertEq(logs[i].topics[2], labelHash, "labelHash topic should match");
                assertEq(
                    logs[i].topics[3],
                    bytes32(uint256(uint160(address(batchRegistrar)))),
                    "sender topic should match"
                );
                break;
            }
        }
        assertTrue(foundLabelReserved, "LabelReserved event should be emitted");

        uint64 newExpiry = uint64(block.timestamp + 86400 * 2);
        expires[0] = newExpiry;

        vm.recordLogs();
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);
        logs = vm.getRecordedLogs();

        bytes32 expiryUpdatedSig = keccak256("ExpiryUpdated(uint256,uint64,address)");
        bool foundExpiryUpdated = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == expiryUpdatedSig) {
                foundExpiryUpdated = true;
                break;
            }
        }
        assertTrue(foundExpiryUpdated, "ExpiryUpdated event should be emitted");
    }

    function test_batchRegister_skips_already_registered_names() public {
        uint64 expiry = uint64(block.timestamp + 86400 * 365);
        string[] memory labels = new string[](1);
        uint64[] memory expires = new uint64[](1);
        labels[0] = "registered";
        expires[0] = expiry;
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTER_RESERVED, address(this));
        address realOwner = address(0x1234);
        ethRegistry.register(
            "registered",
            realOwner,
            IRegistry(address(0)),
            resolver,
            RegistryRolesLib.ROLE_SET_RESOLVER,
            expiry
        );

        IPermissionedRegistry.State memory stateBefore = ethRegistry.getState(
            LibLabel.id("registered")
        );
        assertEq(uint256(stateBefore.status), uint256(IPermissionedRegistry.Status.REGISTERED));

        uint64 newExpiry = uint64(block.timestamp + 86400 * 730);
        string[] memory mixedLabels = new string[](3);
        uint64[] memory mixedExpires = new uint64[](3);
        mixedLabels[0] = "fresh1";
        mixedExpires[0] = newExpiry;
        mixedLabels[1] = "registered";
        mixedExpires[1] = newExpiry;
        mixedLabels[2] = "fresh2";
        mixedExpires[2] = newExpiry;

        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, mixedLabels, mixedExpires);

        IPermissionedRegistry.State memory stateAfter = ethRegistry.getState(
            LibLabel.id("registered")
        );
        assertEq(uint256(stateAfter.status), uint256(IPermissionedRegistry.Status.REGISTERED));
        assertEq(
            ethRegistry.ownerOf(stateAfter.tokenId),
            realOwner,
            "Owner should remain unchanged"
        );
        assertEq(stateAfter.expiry, expiry, "Expiry should remain unchanged");

        IPermissionedRegistry.State memory fresh1 = ethRegistry.getState(LibLabel.id("fresh1"));
        assertEq(uint256(fresh1.status), uint256(IPermissionedRegistry.Status.RESERVED));
        assertEq(fresh1.expiry, newExpiry);

        IPermissionedRegistry.State memory fresh2 = ethRegistry.getState(LibLabel.id("fresh2"));
        assertEq(uint256(fresh2.status), uint256(IPermissionedRegistry.Status.RESERVED));
        assertEq(fresh2.expiry, newExpiry);
    }

    function test_batchRegister_reservedThenRegister() public {
        uint64 expiry = uint64(block.timestamp + 86400 * 365);
        string[] memory labels = new string[](1);
        uint64[] memory expires = new uint64[](1);
        labels[0] = "migratable";
        expires[0] = expiry;
        batchRegistrar.batchRegister(IRegistry(address(0)), resolver, labels, expires);

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id("migratable"));
        assertEq(
            uint256(state.status),
            uint256(IPermissionedRegistry.Status.RESERVED),
            "Should be RESERVED"
        );

        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTER_RESERVED, address(this));

        address realOwner = address(0x1234);
        ethRegistry.register(
            "migratable",
            realOwner,
            IRegistry(address(0)),
            resolver,
            RegistryRolesLib.ROLE_SET_RESOLVER,
            expiry
        );

        state = ethRegistry.getState(LibLabel.id("migratable"));
        assertEq(
            uint256(state.status),
            uint256(IPermissionedRegistry.Status.REGISTERED),
            "Should be REGISTERED"
        );
        assertEq(ethRegistry.ownerOf(state.tokenId), realOwner, "Owner should be realOwner");
    }
}
