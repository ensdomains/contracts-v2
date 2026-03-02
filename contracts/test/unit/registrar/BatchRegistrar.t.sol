// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

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
    address preMigrationController = address(0x1234);
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

        batchRegistrar = new BatchRegistrar(registry);

        // Grant REGISTRAR and RENEW roles to batch registrar
        registry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(batchRegistrar)
        );
    }

    function test_batchRegister_new_names() public {
        BatchRegistrarName[] memory names = new BatchRegistrarName[](3);

        names[0] = BatchRegistrarName({
            label: "test1",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: uint64(block.timestamp + 86400)
        });

        names[1] = BatchRegistrarName({
            label: "test2",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: uint64(block.timestamp + 86400 * 2)
        });

        names[2] = BatchRegistrarName({
            label: "test3",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: uint64(block.timestamp + 86400 * 3)
        });

        batchRegistrar.batchRegister(names);

        // Verify all names were registered
        for (uint256 i = 0; i < names.length; i++) {
            IPermissionedRegistry.State memory state = registry.getState(LibLabel.id(names[i].label));
            assertEq(registry.ownerOf(state.tokenId), preMigrationController, "Owner should be preMigrationController");
            assertEq(state.expiry, names[i].expires, "Expiry should match");
            assertEq(registry.getResolver(names[i].label), resolver, "Resolver should match");
        }
    }

    function test_batchRegister_renews_if_newer_expiry() public {
        // First register the name with a short expiry
        uint64 originalExpiry = uint64(block.timestamp + 86400);
        BatchRegistrarName[] memory initialNames = new BatchRegistrarName[](1);
        initialNames[0] = BatchRegistrarName({
            label: "test",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: originalExpiry
        });
        batchRegistrar.batchRegister(initialNames);

        // Verify initial registration
        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("test"));
        assertEq(state.expiry, originalExpiry, "Initial expiry should match");

        // Now try to "register" again with a later expiry
        uint64 newExpiry = uint64(block.timestamp + 86400 * 365);
        BatchRegistrarName[] memory renewNames = new BatchRegistrarName[](1);
        renewNames[0] = BatchRegistrarName({
            label: "test",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: newExpiry
        });
        batchRegistrar.batchRegister(renewNames);

        // Verify expiry was updated
        state = registry.getState(LibLabel.id("test"));
        assertEq(state.expiry, newExpiry, "Expiry should be renewed");
    }

    function test_batchRegister_skips_if_same_or_older_expiry() public {
        // First register the name with a long expiry
        uint64 originalExpiry = uint64(block.timestamp + 86400 * 365);
        BatchRegistrarName[] memory initialNames = new BatchRegistrarName[](1);
        initialNames[0] = BatchRegistrarName({
            label: "test",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: originalExpiry
        });
        batchRegistrar.batchRegister(initialNames);

        // Verify initial registration
        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("test"));
        assertEq(state.expiry, originalExpiry, "Initial expiry should match");

        // Now try to "register" again with an earlier expiry (should be skipped)
        uint64 earlierExpiry = uint64(block.timestamp + 86400);
        BatchRegistrarName[] memory renewNames = new BatchRegistrarName[](1);
        renewNames[0] = BatchRegistrarName({
            label: "test",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: earlierExpiry
        });
        batchRegistrar.batchRegister(renewNames);

        // Verify expiry was NOT changed
        state = registry.getState(LibLabel.id("test"));
        assertEq(state.expiry, originalExpiry, "Expiry should remain unchanged");
    }

    function test_batchRegister_mixed_new_and_existing() public {
        // Register one name first
        uint64 originalExpiry = uint64(block.timestamp + 86400);
        BatchRegistrarName[] memory initialNames = new BatchRegistrarName[](1);
        initialNames[0] = BatchRegistrarName({
            label: "existing",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: originalExpiry
        });
        batchRegistrar.batchRegister(initialNames);

        // Now batch register with a mix of new and existing names
        uint64 newExpiry = uint64(block.timestamp + 86400 * 365);
        BatchRegistrarName[] memory mixedNames = new BatchRegistrarName[](3);

        mixedNames[0] = BatchRegistrarName({
            label: "new1",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: newExpiry
        });

        mixedNames[1] = BatchRegistrarName({
            label: "existing",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: newExpiry
        });

        mixedNames[2] = BatchRegistrarName({
            label: "new2",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: newExpiry
        });

        batchRegistrar.batchRegister(mixedNames);

        // Verify new names were registered
        IPermissionedRegistry.State memory state1 = registry.getState(LibLabel.id("new1"));
        assertEq(registry.ownerOf(state1.tokenId), preMigrationController, "new1 owner should be preMigrationController");
        assertEq(state1.expiry, newExpiry, "new1 expiry should match");

        IPermissionedRegistry.State memory state2 = registry.getState(LibLabel.id("new2"));
        assertEq(registry.ownerOf(state2.tokenId), preMigrationController, "new2 owner should be preMigrationController");
        assertEq(state2.expiry, newExpiry, "new2 expiry should match");

        // Verify existing name was renewed
        IPermissionedRegistry.State memory existingState = registry.getState(LibLabel.id("existing"));
        assertEq(existingState.expiry, newExpiry, "existing expiry should be renewed");
    }

    function test_batchRegister_registers_expired_names() public {
        // First register a name
        uint64 originalExpiry = uint64(block.timestamp + 86400);
        BatchRegistrarName[] memory initialNames = new BatchRegistrarName[](1);
        initialNames[0] = BatchRegistrarName({
            label: "expiring",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: originalExpiry
        });
        batchRegistrar.batchRegister(initialNames);

        // Warp past expiry
        vm.warp(block.timestamp + 86401);

        // Now try to register the same name again (should succeed as a new registration)
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

        // Verify name was re-registered with new owner
        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("expiring"));
        assertEq(registry.ownerOf(state.tokenId), newOwner, "Owner should be newOwner");
        assertEq(state.expiry, newExpiry, "Expiry should match new expiry");
    }

    function test_batchRegister_empty_array() public {
        BatchRegistrarName[] memory emptyNames = new BatchRegistrarName[](0);

        // Should not revert
        batchRegistrar.batchRegister(emptyNames);
    }

    function test_batchRegister_single_name() public {
        BatchRegistrarName[] memory singleName = new BatchRegistrarName[](1);
        singleName[0] = BatchRegistrarName({
            label: "single",
            owner: preMigrationController,
            registry: IRegistry(address(0)),
            resolver: resolver,
            roleBitmap: RegistryRolesLib.ROLE_SET_RESOLVER,
            expires: uint64(block.timestamp + 86400)
        });

        batchRegistrar.batchRegister(singleName);

        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id("single"));
        assertEq(registry.ownerOf(state.tokenId), preMigrationController, "Owner should be preMigrationController");
        assertEq(state.expiry, singleName[0].expires, "Expiry should match");
    }
}
