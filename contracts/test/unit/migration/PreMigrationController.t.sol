// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file

import {Test, Vm} from "forge-std/Test.sol";

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IRegistryMetadata} from "~src/registry/interfaces/IRegistryMetadata.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {PreMigrationController} from "~src/migration/PreMigrationController.sol";
import {IPreMigrationController} from "~src/migration/interfaces/IPreMigrationController.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract MockRegistryMetadata is IRegistryMetadata {
    function tokenUri(uint256) external pure override returns (string memory) {
        return "";
    }
}

contract PreMigrationControllerTest is Test, ERC1155Holder {
    PreMigrationController controller;
    MockRegistryMetadata metadata;
    PermissionedRegistry registry;
    MockHCAFactoryBasic hcaFactory;

    address owner = address(this);
    address user = address(0x1234);
    address migrationController = address(0x5678);
    address resolver = address(0xABCD);

    string testLabel = "test";
    uint256 testTokenId;

    function setUp() public {
        metadata = new MockRegistryMetadata();
        hcaFactory = new MockHCAFactoryBasic();

        registry = new PermissionedRegistry(
            hcaFactory,
            metadata,
            owner,
            EACBaseRolesLib.ALL_ROLES
        );

        controller = new PreMigrationController(
            registry,
            hcaFactory,
            owner,
            EACBaseRolesLib.ALL_ROLES
        );

        // Grant REGISTRAR role to this test contract so we can register names
        registry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR,
            address(this)
        );

        // Grant controller roles it needs on the registry
        registry.grantRootRoles(
            RegistryRolesLib.ROLE_SET_SUBREGISTRY |
            RegistryRolesLib.ROLE_SET_RESOLVER,
            address(controller)
        );

        // Grant MIGRATION_CONTROLLER role to the mock migration controller
        controller.grantRootRoles(
            controller.ROLE_MIGRATION_CONTROLLER(),
            migrationController
        );

        testTokenId = uint256(keccak256(bytes(testLabel)));
    }

    function _preMigrateName(string memory label, uint64 expires) internal returns (uint256 tokenId) {
        // Register the name with controller as owner and ALL roles (matches pre-migration behavior)
        tokenId = registry.register(
            label,
            address(controller),
            IRegistry(address(0)),
            address(1),
            EACBaseRolesLib.ALL_ROLES,
            expires
        );
    }

    function test_claim_sets_properties() public {
        uint64 expires = uint64(block.timestamp + 86400);
        uint256 tokenId = _preMigrateName(testLabel, expires);

        address newSubregistry = address(0x9999);

        vm.prank(migrationController);
        controller.claim(
            testLabel,
            user,
            IRegistry(newSubregistry),
            resolver
        );

        // Verify owner changed
        IPermissionedRegistry.State memory state = registry.getState(LibLabel.id(testLabel));
        assertEq(registry.ownerOf(state.tokenId), user, "Owner should be the user");

        // Verify subregistry was set
        assertEq(address(registry.getSubregistry(testLabel)), newSubregistry, "Subregistry should be set");

        // Verify resolver was set
        assertEq(registry.getResolver(testLabel), resolver, "Resolver should be set");

        // Verify ALL roles were transferred from pre-migration
        assertTrue(registry.hasRoles(state.tokenId, EACBaseRolesLib.ALL_ROLES, user), "User should have ALL_ROLES");
    }

    function test_claim_transfers_ownership() public {
        uint64 expires = uint64(block.timestamp + 86400);
        uint256 tokenId = _preMigrateName(testLabel, expires);

        // Verify controller owns the name initially
        assertEq(registry.ownerOf(tokenId), address(controller), "Controller should own name initially");

        vm.prank(migrationController);
        controller.claim(
            testLabel,
            user,
            IRegistry(address(0)),
            address(0)
        );

        // Verify user now owns the name
        assertEq(registry.ownerOf(tokenId), user, "User should own name after claim");
    }

    function test_claim_with_zero_subregistry() public {
        uint64 expires = uint64(block.timestamp + 86400);
        _preMigrateName(testLabel, expires);

        vm.prank(migrationController);
        controller.claim(
            testLabel,
            user,
            IRegistry(address(0)),
            resolver
        );

        // Verify subregistry is still zero
        assertEq(address(registry.getSubregistry(testLabel)), address(0), "Subregistry should remain zero");
    }

    function test_claim_with_zero_resolver() public {
        uint64 expires = uint64(block.timestamp + 86400);
        _preMigrateName(testLabel, expires);

        vm.prank(migrationController);
        controller.claim(
            testLabel,
            user,
            IRegistry(address(0x9999)),
            address(0)
        );

        // Verify resolver was overwritten to zero
        assertEq(registry.getResolver(testLabel), address(0), "Resolver should be overwritten to zero");
    }

    function test_Revert_not_migration_controller() public {
        uint64 expires = uint64(block.timestamp + 86400);
        _preMigrateName(testLabel, expires);

        // Try to claim without the ROLE_MIGRATION_CONTROLLER
        vm.expectRevert();
        vm.prank(user);
        controller.claim(
            testLabel,
            user,
            IRegistry(address(0)),
            address(0)
        );
    }

    function test_Revert_name_not_owned() public {
        uint64 expires = uint64(block.timestamp + 86400);

        // Register the name with user as owner (not controller)
        registry.register(
            testLabel,
            user,
            IRegistry(address(0)),
            address(0),
            RegistryRolesLib.ROLE_SET_RESOLVER | RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN,
            expires
        );

        vm.expectRevert(abi.encodeWithSelector(PreMigrationController.NameNotOwned.selector, testLabel, user));
        vm.prank(migrationController);
        controller.claim(
            testLabel,
            user,
            IRegistry(address(0)),
            address(0)
        );
    }

    function test_Revert_name_expired() public {
        uint64 expires = uint64(block.timestamp + 86400);
        _preMigrateName(testLabel, expires);

        // Fast forward past expiry
        vm.warp(block.timestamp + 86401);

        vm.expectRevert(abi.encodeWithSelector(PreMigrationController.NameExpired.selector, testLabel));
        vm.prank(migrationController);
        controller.claim(
            testLabel,
            user,
            IRegistry(address(0)),
            address(0)
        );
    }

    function test_onERC1155Received() public {
        // Verify controller can receive ERC1155 tokens
        bytes4 selector = controller.onERC1155Received(
            address(this),
            address(this),
            1,
            1,
            ""
        );
        assertEq(selector, IERC1155Receiver.onERC1155Received.selector, "Should return correct selector");
    }

    function test_onERC1155BatchReceived() public {
        // Verify controller can receive batch ERC1155 tokens
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 2;
        uint256[] memory values = new uint256[](2);
        values[0] = 1;
        values[1] = 1;

        bytes4 selector = controller.onERC1155BatchReceived(
            address(this),
            address(this),
            ids,
            values,
            ""
        );
        assertEq(selector, IERC1155Receiver.onERC1155BatchReceived.selector, "Should return correct selector");
    }

    function test_supportsInterface() public view {
        assertTrue(controller.supportsInterface(type(IERC1155Receiver).interfaceId), "Should support IERC1155Receiver");
        assertTrue(controller.supportsInterface(type(IPreMigrationController).interfaceId), "Should support IPreMigrationController");
    }

    function test_claim_transfers_all_roles() public {
        uint64 expires = uint64(block.timestamp + 86400);
        uint256 tokenId = _preMigrateName(testLabel, expires);

        // Verify controller has ALL_ROLES initially
        assertTrue(registry.hasRoles(tokenId, EACBaseRolesLib.ALL_ROLES, address(controller)), "Controller should have ALL_ROLES initially");

        vm.prank(migrationController);
        controller.claim(
            testLabel,
            user,
            IRegistry(address(0)),
            address(0)
        );

        // Verify user now has ALL roles
        assertTrue(registry.hasRoles(tokenId, EACBaseRolesLib.ALL_ROLES, user), "User should have ALL_ROLES after claim");

        // Verify controller no longer has roles
        assertFalse(registry.hasRoles(tokenId, EACBaseRolesLib.ALL_ROLES, address(controller)), "Controller should NOT have roles after transfer");
    }

    function test_claim_emits_event() public {
        uint64 expires = uint64(block.timestamp + 86400);
        _preMigrateName(testLabel, expires);

        address newSubregistry = address(0x9999);

        vm.recordLogs();

        vm.prank(migrationController);
        controller.claim(
            testLabel,
            user,
            IRegistry(newSubregistry),
            resolver
        );

        Vm.Log[] memory entries = vm.getRecordedLogs();

        // Find the NameClaimed event
        bool foundEvent = false;
        for (uint256 i = 0; i < entries.length; i++) {
            if (entries[i].topics[0] == keccak256("NameClaimed(string,address,address,address)")) {
                foundEvent = true;
                // topics[1] is indexed label (hashed)
                // topics[2] is indexed owner
                assertEq(address(uint160(uint256(entries[i].topics[2]))), user, "Event owner should match");
                break;
            }
        }
        assertTrue(foundEvent, "NameClaimed event should be emitted");
    }
}
