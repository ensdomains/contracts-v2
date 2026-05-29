// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {CANNOT_UNWRAP} from "@ens/contracts/wrapper/NameWrapper.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {UnauthorizedCaller, WrongParentToken} from "~src/CommonErrors.sol";
import {ApprovedUpgradeGate} from "~src/registry/ApprovedUpgradeGate.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IWrapperRegistry} from "~src/registry/interfaces/IWrapperRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {WrapperRegistry} from "~src/registry/WrapperRegistry.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {LockedMigrationController} from "~src/migration/LockedMigrationController.sol";
import {LibMigration} from "~src/migration/libraries/LibMigration.sol";
import {REGISTRATION_ROLE_BITMAP} from "~src/registrar/ETHRegistrar.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {PermissionedAddressSet} from "~src/utils/PermissionedAddressSet.sol";
import {PublicResolverV2} from "~src/resolver/PublicResolverV2.sol";
import {MigrationControllerFixture} from "~test/fixtures/MigrationControllerFixture.sol";

contract WrapperRegistryRoleTransferTest is MigrationControllerFixture {
    LockedMigrationController migrationController;
    WrapperRegistry wrapperRegistryImpl;
    ApprovedUpgradeGate approvedUpgradeGate;
    PermissionedAddressSet publicResolverSet;
    PublicResolverV2 publicResolver;

    address buyer = makeAddr("buyer");
    address delegate = makeAddr("delegate");

    uint256 internal constant TOKEN_OWNER_ROLES =
        RegistryRolesLib.ROLE_SET_RESOLVER |
        RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN |
        RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN |
        RegistryRolesLib.ROLE_WAS_RESERVED;

    uint256 internal constant SUBREG_ROOT_ROLES =
        RegistryRolesLib.ROLE_REGISTRAR |
        RegistryRolesLib.ROLE_REGISTRAR_ADMIN |
        RegistryRolesLib.ROLE_RENEW |
        RegistryRolesLib.ROLE_RENEW_ADMIN |
        RegistryRolesLib.ROLE_UPGRADE |
        RegistryRolesLib.ROLE_UPGRADE_ADMIN;

    function setUp() external {
        deployMigrationControllerFixture();

        approvedUpgradeGate = new ApprovedUpgradeGate(address(this));
        publicResolverSet = new PermissionedAddressSet(hcaFactory, address(this));
        publicResolver = new PublicResolverV2(hcaFactory, nameWrapper, rootRegistry);

        wrapperRegistryImpl = new WrapperRegistry(
            nameWrapper,
            address(graveyard),
            verifiableFactory,
            address(ensV1Resolver),
            hcaFactory,
            approvedUpgradeGate,
            labelStore,
            publicResolverSet,
            address(publicResolver)
        );

        migrationController = new LockedMigrationController(
            nameWrapper,
            address(graveyard),
            ethRegistry,
            verifiableFactory,
            address(wrapperRegistryImpl),
            publicResolverSet,
            address(publicResolver)
        );

        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(migrationController)
        );
    }

    /// @dev Migrate a locked-but-transferable name, returning the WrapperRegistry created.
    function _migrateLocked(string memory label) internal returns (WrapperRegistry sub) {
        bytes memory name = registerWrappedETH2LD(label, CANNOT_UNWRAP);
        LibMigration.Data memory md = _lockedData(name);
        md.label = label;
        vm.prank(testOwner);
        nameWrapper.safeTransferFrom(
            testOwner,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );
        sub = WrapperRegistry(address(ethRegistry.getSubregistry(label)));
    }

    function test_transfer_propagatesRootRolesToBuyer() external {
        WrapperRegistry sub = _migrateLocked("nick");
        uint256 tokenId = ethRegistry.findTokenId("nick");

        assertEq(sub.roles(sub.ROOT_RESOURCE(), testOwner), SUBREG_ROOT_ROLES, "seed");
        assertEq(sub.roles(sub.ROOT_RESOURCE(), buyer), 0, "buyer pre");

        vm.prank(testOwner);
        ethRegistry.safeTransferFrom(testOwner, buyer, tokenId, 1, "");

        assertEq(sub.roles(sub.ROOT_RESOURCE(), testOwner), 0, "seller post");
        assertEq(sub.roles(sub.ROOT_RESOURCE(), buyer), SUBREG_ROOT_ROLES, "buyer post");
    }

    function test_transfer_buyerCanRegisterSubdomain() external {
        WrapperRegistry sub = _migrateLocked("nick");
        uint256 tokenId = ethRegistry.findTokenId("nick");
        vm.prank(testOwner);
        ethRegistry.safeTransferFrom(testOwner, buyer, tokenId, 1, "");

        vm.prank(buyer);
        sub.register("child", buyer, IRegistry(address(0)), address(0), 0, _soon());
        assertEq(sub.findOwner("child"), buyer, "child owner");
    }

    function test_transfer_sellerLosesRegistrar() external {
        WrapperRegistry sub = _migrateLocked("nick");
        uint256 tokenId = ethRegistry.findTokenId("nick");
        vm.prank(testOwner);
        ethRegistry.safeTransferFrom(testOwner, buyer, tokenId, 1, "");

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                sub.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_REGISTRAR,
                testOwner
            )
        );
        vm.prank(testOwner);
        sub.register("child", testOwner, IRegistry(address(0)), address(0), 0, _soon());
    }

    function test_transfer_delegateRetainsRole() external {
        WrapperRegistry sub = _migrateLocked("nick");
        uint256 tokenId = ethRegistry.findTokenId("nick");

        vm.prank(testOwner);
        sub.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, delegate);

        assertTrue(sub.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, delegate), "delegate pre");

        vm.prank(testOwner);
        ethRegistry.safeTransferFrom(testOwner, buyer, tokenId, 1, "");

        assertTrue(sub.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, delegate), "delegate post");
        assertTrue(sub.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, buyer), "buyer post");
        assertFalse(sub.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, testOwner), "seller post");
    }

    function test_transferRootRoles_unauthorizedDirectCall() external {
        WrapperRegistry sub = _migrateLocked("nick");

        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, address(this)));
        sub.transferRootRoles(0, testOwner, buyer);
    }

    function test_transferRootRoles_rejectsCrossTokenDrain() external {
        WrapperRegistry sub = _migrateLocked("nick");

        // Register an unlocked sibling that the attacker controls and that grants
        // them ROLE_SET_SUBREGISTRY. They then point that sibling's subregistry at
        // nick's WrapperRegistry and try to trigger transferRootRoles via a transfer.
        address attacker = makeAddr("attacker");
        ethRegistry.register(
            "evil",
            attacker,
            IRegistry(address(0)),
            address(0),
            REGISTRATION_ROLE_BITMAP,
            _soon()
        );
        uint256 evilTokenId = ethRegistry.findTokenId("evil");

        vm.prank(attacker);
        ethRegistry.setSubregistry(evilTokenId, sub);

        // Sanity: getResource of evilTokenId differs from nick's labelhash.
        assertTrue(LibLabel.withVersion(evilTokenId, 0) != LibLabel.id("nick"), "labelhash differs");

        address mallory = makeAddr("mallory");
        vm.expectRevert(abi.encodeWithSelector(WrongParentToken.selector, evilTokenId));
        vm.prank(attacker);
        ethRegistry.safeTransferFrom(attacker, mallory, evilTokenId, 1, "");
    }

    function test_transfer_emptySubregistryNoOp() external {
        address owner = makeAddr("emptyOwner");
        ethRegistry.register(
            "naked",
            owner,
            IRegistry(address(0)),
            address(0),
            REGISTRATION_ROLE_BITMAP,
            _soon()
        );
        uint256 tokenId = ethRegistry.findTokenId("naked");
        vm.prank(owner);
        ethRegistry.safeTransferFrom(owner, buyer, tokenId, 1, "");
        assertEq(ethRegistry.ownerOf(ethRegistry.findTokenId("naked")), buyer);
    }

    function test_transfer_nonWrapperSubregistryNoOp() external {
        address owner = makeAddr("userOwner");
        UserRegistry userSub = deployUserRegistry(owner, 0, 1);
        ethRegistry.register("user", owner, userSub, address(0), REGISTRATION_ROLE_BITMAP, _soon());
        uint256 tokenId = ethRegistry.findTokenId("user");
        vm.prank(owner);
        ethRegistry.safeTransferFrom(owner, buyer, tokenId, 1, "");
        assertEq(ethRegistry.ownerOf(ethRegistry.findTokenId("user")), buyer);
        // sanity: userSub does not implement IWrapperRegistry so the hook is a no-op
        assertFalse(
            ERC165Checker.supportsInterface(address(userSub), type(IWrapperRegistry).interfaceId),
            "not a WrapperRegistry"
        );
    }

    function test_setParent_isRejectedOnWrapperRegistry() external {
        WrapperRegistry sub = _migrateLocked("nick");
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                sub.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_SET_PARENT,
                address(this)
            )
        );
        sub.setParent(IRegistry(address(0)), "different");
    }
}
