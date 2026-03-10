// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file

import {Test, Vm} from "forge-std/Test.sol";

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IRegistryMetadata} from "~src/registry/interfaces/IRegistryMetadata.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {BatchRegistrar, BatchRegistrarName} from "~src/registrar/BatchRegistrar.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract MockRegistryMetadata is IRegistryMetadata {
    function tokenUri(uint256) external pure override returns (string memory) {
        return "";
    }
}

contract BatchRegistrarTest is Test, ERC1155Holder {
    BatchRegistrar batchRegistrar;
    MockRegistryMetadata metadata;
    PermissionedRegistry registry;
    MockHCAFactoryBasic hcaFactory;

    address owner = address(this);
    address resolver = address(0xABCD);

    function setUp() public {
        metadata = new MockRegistryMetadata();
        hcaFactory = new MockHCAFactoryBasic();

        registry = new PermissionedRegistry(
            hcaFactory,
            metadata,
            owner,
            EACBaseRolesLib.ALL_ROLES
        );

        batchRegistrar = new BatchRegistrar(registry, owner);

        registry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(batchRegistrar)
        );
    }

    function test_batchRegister_new_names() public {
        BatchRegistrarName[] memory names = new BatchRegistrarName[](3);

        names[0] = BatchRegistrarName({
            label: "test1",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: uint64(block.timestamp + 86400)
        });

        names[1] = BatchRegistrarName({
            label: "test2",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: uint64(block.timestamp + 86400 * 2)
        });

        names[2] = BatchRegistrarName({
            label: "test3",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: uint64(block.timestamp + 86400 * 3)
        });

        batchRegistrar.batchRegister(names);

        for (uint256 i = 0; i < names.length; i++) {
            IPermissionedRegistry.State memory state = registry.getState(LibLabel.id(names[i].label));
            assertEq(uint256(state.status), uint256(IPermissionedRegistry.Status.RESERVED), "Status should be RESERVED");
            assertEq(state.expiry, names[i].expires, "Expiry should match");
            assertEq(registry.getResolver(names[i].label), resolver, "Resolver should match");
        }
    }

    function test_batchRegister_renews_if_newer_expiry() public {
        uint64 originalExpiry = uint64(block.timestamp + 86400);
        BatchRegistrarName[] memory initialNames = new BatchRegistrarName[](1);
        initialNames[0] = BatchRegistrarName({
            label: "test",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: originalExpiry
        });
        batchRegistrar.batchRegister(initialNames);

        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("test"));
        assertEq(state.expiry, originalExpiry, "Initial expiry should match");

        uint64 newExpiry = uint64(block.timestamp + 86400 * 365);
        BatchRegistrarName[] memory renewNames = new BatchRegistrarName[](1);
        renewNames[0] = BatchRegistrarName({
            label: "test",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: newExpiry
        });
        batchRegistrar.batchRegister(renewNames);

        state = registry.getState(LibLabel.id("test"));
        assertEq(state.expiry, newExpiry, "Expiry should be renewed");
    }

    function test_batchRegister_skips_if_same_or_older_expiry() public {
        uint64 originalExpiry = uint64(block.timestamp + 86400 * 365);
        BatchRegistrarName[] memory initialNames = new BatchRegistrarName[](1);
        initialNames[0] = BatchRegistrarName({
            label: "test",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: originalExpiry
        });
        batchRegistrar.batchRegister(initialNames);

        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("test"));
        assertEq(state.expiry, originalExpiry, "Initial expiry should match");

        uint64 earlierExpiry = uint64(block.timestamp + 86400);
        BatchRegistrarName[] memory renewNames = new BatchRegistrarName[](1);
        renewNames[0] = BatchRegistrarName({
            label: "test",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: earlierExpiry
        });
        batchRegistrar.batchRegister(renewNames);

        state = registry.getState(LibLabel.id("test"));
        assertEq(state.expiry, originalExpiry, "Expiry should remain unchanged");
    }

    function test_batchRegister_mixed_new_and_existing() public {
        uint64 originalExpiry = uint64(block.timestamp + 86400);
        BatchRegistrarName[] memory initialNames = new BatchRegistrarName[](1);
        initialNames[0] = BatchRegistrarName({
            label: "existing",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: originalExpiry
        });
        batchRegistrar.batchRegister(initialNames);

        uint64 newExpiry = uint64(block.timestamp + 86400 * 365);
        BatchRegistrarName[] memory mixedNames = new BatchRegistrarName[](3);

        mixedNames[0] = BatchRegistrarName({
            label: "new1",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: newExpiry
        });

        mixedNames[1] = BatchRegistrarName({
            label: "existing",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: newExpiry
        });

        mixedNames[2] = BatchRegistrarName({
            label: "new2",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: newExpiry
        });

        batchRegistrar.batchRegister(mixedNames);

        IPermissionedRegistry.State memory state1 = registry.getState(LibLabel.id("new1"));
        assertEq(uint256(state1.status), uint256(IPermissionedRegistry.Status.RESERVED), "new1 should be RESERVED");
        assertEq(state1.expiry, newExpiry, "new1 expiry should match");

        IPermissionedRegistry.State memory state2 = registry.getState(LibLabel.id("new2"));
        assertEq(uint256(state2.status), uint256(IPermissionedRegistry.Status.RESERVED), "new2 should be RESERVED");
        assertEq(state2.expiry, newExpiry, "new2 expiry should match");

        IPermissionedRegistry.State memory existingState = registry.getState(LibLabel.id("existing"));
        assertEq(existingState.expiry, newExpiry, "existing expiry should be renewed");
    }

    function test_batchRegister_registers_expired_names() public {
        uint64 originalExpiry = uint64(block.timestamp + 86400);
        BatchRegistrarName[] memory initialNames = new BatchRegistrarName[](1);
        initialNames[0] = BatchRegistrarName({
            label: "expiring",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: originalExpiry
        });
        batchRegistrar.batchRegister(initialNames);

        vm.warp(block.timestamp + 86401);

        uint64 newExpiry = uint64(block.timestamp + 86400 * 365);
        address newOwner = address(0x9999);
        BatchRegistrarName[] memory reregisterNames = new BatchRegistrarName[](1);
        reregisterNames[0] = BatchRegistrarName({
            label: "expiring",
            owner: newOwner,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: newExpiry
        });
        batchRegistrar.batchRegister(reregisterNames);

        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("expiring"));
        assertEq(registry.ownerOf(state.tokenId), newOwner, "Owner should be newOwner");
        assertEq(state.expiry, newExpiry, "Expiry should match new expiry");
        assertEq(registry.getResolver("expiring"), resolver, "Resolver should be set on re-registration");
    }

    function test_batchRegister_empty_array() public {
        BatchRegistrarName[] memory emptyNames = new BatchRegistrarName[](0);
        batchRegistrar.batchRegister(emptyNames);
    }

    function test_batchRegister_single_name() public {
        BatchRegistrarName[] memory singleName = new BatchRegistrarName[](1);
        singleName[0] = BatchRegistrarName({
            label: "single",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: uint64(block.timestamp + 86400)
        });

        batchRegistrar.batchRegister(singleName);

        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("single"));
        assertEq(uint256(state.status), uint256(IPermissionedRegistry.Status.RESERVED), "Status should be RESERVED");
        assertEq(state.expiry, singleName[0].expires, "Expiry should match");
    }

    function test_batchRegister_onlyOwner() public {
        BatchRegistrarName[] memory names = new BatchRegistrarName[](1);
        names[0] = BatchRegistrarName({
            label: "test",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: uint64(block.timestamp + 86400)
        });

        address unauthorized = address(0xBEEF);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, unauthorized));
        vm.prank(unauthorized);
        batchRegistrar.batchRegister(names);
    }

    function test_batchRegister_duplicateLabelsInBatch() public {
        BatchRegistrarName[] memory names = new BatchRegistrarName[](2);
        uint64 expiry1 = uint64(block.timestamp + 86400);
        uint64 expiry2 = uint64(block.timestamp + 86400 * 2);

        names[0] = BatchRegistrarName({
            label: "duplicate",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: expiry1
        });

        names[1] = BatchRegistrarName({
            label: "duplicate",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: expiry2
        });

        batchRegistrar.batchRegister(names);

        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("duplicate"));
        assertEq(uint256(state.status), uint256(IPermissionedRegistry.Status.RESERVED), "Status should be RESERVED");
        assertEq(state.expiry, expiry2, "Expiry should be the renewed (second) value");
    }

    function test_batchRegister_events() public {
        BatchRegistrarName[] memory names = new BatchRegistrarName[](1);
        uint64 expiry = uint64(block.timestamp + 86400);
        names[0] = BatchRegistrarName({
            label: "eventtest",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: expiry
        });

        vm.recordLogs();
        batchRegistrar.batchRegister(names);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 nameReservedSig = keccak256("NameReserved(uint256,bytes32,string,uint64,address)");
        bool foundNameReserved = false;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].topics[0] == nameReservedSig) {
                foundNameReserved = true;
                bytes32 labelHash = keccak256(bytes("eventtest"));
                assertEq(logs[i].topics[2], labelHash, "labelHash topic should match");
                assertEq(logs[i].topics[3], bytes32(uint256(uint160(address(batchRegistrar)))), "sender topic should match");
                break;
            }
        }
        assertTrue(foundNameReserved, "NameReserved event should be emitted");

        // Renew and check ExpiryUpdated event
        uint64 newExpiry = uint64(block.timestamp + 86400 * 2);
        names[0].expires = newExpiry;

        vm.recordLogs();
        batchRegistrar.batchRegister(names);
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
        // Reserve a name first
        uint64 expiry = uint64(block.timestamp + 86400 * 365);
        BatchRegistrarName[] memory initialNames = new BatchRegistrarName[](1);
        initialNames[0] = BatchRegistrarName({
            label: "registered",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: expiry
        });
        batchRegistrar.batchRegister(initialNames);

        // Promote to REGISTERED with a real owner
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTER_RESERVED, address(this));
        address realOwner = address(0x1234);
        registry.register(
            "registered",
            realOwner,
            IRegistry(address(0)),
            resolver,
            RegistryRolesLib.ROLE_SET_RESOLVER,
            expiry
        );

        IPermissionedRegistry.State memory stateBefore = registry.getState(LibLabel.id("registered"));
        assertEq(uint256(stateBefore.status), uint256(IPermissionedRegistry.Status.REGISTERED));

        // Batch with a mix of new and already-REGISTERED names should not revert
        uint64 newExpiry = uint64(block.timestamp + 86400 * 730);
        BatchRegistrarName[] memory mixedNames = new BatchRegistrarName[](3);
        mixedNames[0] = BatchRegistrarName({
            label: "fresh1",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: newExpiry
        });
        mixedNames[1] = BatchRegistrarName({
            label: "registered",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: newExpiry
        });
        mixedNames[2] = BatchRegistrarName({
            label: "fresh2",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: newExpiry
        });
        batchRegistrar.batchRegister(mixedNames);

        // The REGISTERED name should be untouched
        IPermissionedRegistry.State memory stateAfter = registry.getState(LibLabel.id("registered"));
        assertEq(uint256(stateAfter.status), uint256(IPermissionedRegistry.Status.REGISTERED));
        assertEq(registry.ownerOf(stateAfter.tokenId), realOwner, "Owner should remain unchanged");
        assertEq(stateAfter.expiry, expiry, "Expiry should remain unchanged");

        // New names should be reserved
        IPermissionedRegistry.State memory fresh1 = registry.getState(LibLabel.id("fresh1"));
        assertEq(uint256(fresh1.status), uint256(IPermissionedRegistry.Status.RESERVED));
        assertEq(fresh1.expiry, newExpiry);

        IPermissionedRegistry.State memory fresh2 = registry.getState(LibLabel.id("fresh2"));
        assertEq(uint256(fresh2.status), uint256(IPermissionedRegistry.Status.RESERVED));
        assertEq(fresh2.expiry, newExpiry);
    }

    function test_batchRegister_reservedThenRegister() public {
        // Reserve with owner=0
        BatchRegistrarName[] memory names = new BatchRegistrarName[](1);
        uint64 expiry = uint64(block.timestamp + 86400 * 365);
        names[0] = BatchRegistrarName({
            label: "migratable",
            owner: address(0),
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: 0,
            expires: expiry
        });
        batchRegistrar.batchRegister(names);

        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("migratable"));
        assertEq(uint256(state.status), uint256(IPermissionedRegistry.Status.RESERVED), "Should be RESERVED");

        // Grant REGISTER_RESERVED role to this test contract so it can promote
        registry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(this)
        );

        // Promote to REGISTERED with an actual owner
        address realOwner = address(0x1234);
        registry.register(
            "migratable",
            realOwner,
            IRegistry(address(0)),
            resolver,
            RegistryRolesLib.ROLE_SET_RESOLVER,
            expiry
        );

        state = registry.getState(LibLabel.id("migratable"));
        assertEq(uint256(state.status), uint256(IPermissionedRegistry.Status.REGISTERED), "Should be REGISTERED");
        assertEq(registry.ownerOf(state.tokenId), realOwner, "Owner should be realOwner");
    }
}
