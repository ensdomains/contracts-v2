// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {console} from "forge-std/console.sol";
import {
    INameWrapper,
    OperationProhibited,
    CANNOT_UNWRAP,
    CAN_DO_EVERYTHING,
    CANNOT_APPROVE,
    CANNOT_BURN_FUSES,
    CANNOT_TRANSFER,
    CANNOT_SET_RESOLVER,
    CANNOT_SET_TTL,
    CANNOT_CREATE_SUBDOMAIN,
    PARENT_CANNOT_CONTROL,
    IS_DOT_ETH,
    CAN_EXTEND_EXPIRY
} from "@ens/contracts/wrapper/NameWrapper.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {InvalidOwner, UnauthorizedCaller} from "~src/CommonErrors.sol";
import {ENSV1Resolver} from "~src/resolver/ENSV1Resolver.sol";
import {ENSV2Resolver} from "~src/resolver/ENSV2Resolver.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {WrappedErrorLib} from "~src/utils/WrappedErrorLib.sol";
import {
    LockedMigrationController,
    IPermissionedRegistry
} from "~src/migration/LockedMigrationController.sol";
import {
    IEnhancedAccessControl,
    EACBaseRolesLib
} from "~src/access-control/EnhancedAccessControl.sol";
import {
    WrapperRegistry,
    IWrapperRegistry,
    IStandardRegistry,
    IRegistry,
    UUPSUpgradeable,
    RegistryRolesLib,
    LibMigration
} from "~src/registry/WrapperRegistry.sol";
import {IRegistryEvents} from "~src/registry/interfaces/IRegistryEvents.sol";
import {
    MigrationControllerFixture,
    ERC165Checker,
    NameCoder
} from "./MigrationControllerFixture.sol";
import {V1Fixture, ENS} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture, VerifiableFactory} from "~test/fixtures/V2Fixture.sol";

contract LockedMigrationControllerTest is MigrationControllerFixture {
    LockedMigrationController migrationController;
    WrapperRegistry wrapperRegistryImpl;

    function setUp() public override {
        super.setUp();
        wrapperRegistryImpl = new WrapperRegistry(
            nameWrapper,
            verifiableFactory,
            address(ensV1Resolver),
            hcaFactory,
            metadata
        );
        migrationController = new LockedMigrationController(
            nameWrapper,
            ethRegistry,
            verifiableFactory,
            address(wrapperRegistryImpl)
        );
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, premigrationController);
        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(migrationController)
        );
        ethRegistrarV1.setResolver(address(ensV2Resolver));
    }

    function test_constructor() external view {
        assertEq(address(migrationController.ETH_REGISTRY()), address(ethRegistry), "ETH_REGISTRY");
        assertEq(address(migrationController.NAME_WRAPPER()), address(nameWrapper), "NAME_WRAPPER");
        assertEq(
            address(migrationController.VERIFIABLE_FACTORY()),
            address(verifiableFactory),
            "VERIFIABLE_FACTORY"
        );
        assertEq(
            migrationController.WRAPPER_REGISTRY_IMPL(),
            address(wrapperRegistryImpl),
            "WRAPPER_REGISTRY_IMPL"
        );
        assertEq(migrationController.getWrappedName(), NameCoder.encode("eth"), "getWrappedName");
        assertEq(migrationController.getWrappedNode(), NameCoder.ETH_NODE, "getWrappedNode");
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(
                address(migrationController),
                type(IERC1155Receiver).interfaceId
            ),
            "IERC1155Receiver"
        );
    }

    function test_finishERC1155Migration_unauthorizedCaller() external {
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, user));
        vm.prank(user);
        migrationController.finishERC1155Migration(new uint256[](0), new LibMigration.Data[](0));
    }

    function test_safeTransferFrom_unauthorizedCaller() external {
        uint256 tokenId = dummy1155.mint(user);
        vm.expectRevert(
            WrappedErrorLib.wrap(abi.encodeWithSelector(UnauthorizedCaller.selector, dummy1155))
        );
        vm.prank(user);
        dummy1155.safeTransferFrom(user, address(migrationController), tokenId, 1, ""); // wrong
    }

    function test_migrate_invalidData() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        vm.expectRevert(
            WrappedErrorLib.wrap(abi.encodeWithSelector(LibMigration.InvalidData.selector))
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            "" // wrong
        );
    }

    function test_migrate_invalidArrayLength() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        uint256[] memory ids = new uint256[](1);
        uint256[] memory amounts = new uint256[](1);
        LibMigration.Data[] memory mds = new LibMigration.Data[](1);
        ids[0] = uint256(NameCoder.namehash(name, 0));
        mds[0] = _makeData(name);
        amounts[0] = 1;
        bytes memory payload = abi.encode(mds);
        uint256 fakeLength = 0;
        assembly {
            mstore(add(payload, 64), fakeLength) // wrong
        }
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(
                    IERC1155Errors.ERC1155InvalidArrayLength.selector,
                    ids.length,
                    fakeLength
                )
            )
        );
        vm.prank(user);
        nameWrapper.safeBatchTransferFrom(
            user,
            address(migrationController),
            ids,
            amounts,
            payload
        );
    }

    function test_migrate_invalidOwner() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        LibMigration.Data memory md = _makeData(name);
        md.owner = address(0); // wrong
        vm.expectRevert(WrappedErrorLib.wrap(abi.encodeWithSelector(InvalidOwner.selector)));
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );
    }

    function test_migrate_invalidReceiver() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        LibMigration.Data memory md = _makeData(name);
        md.owner = address(ethRegistry); // not a IERC1155Receiver
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, md.owner)
            )
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );
    }

    function test_migrate_nameDataMismatch() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes32 node = NameCoder.namehash(name, 0);
        LibMigration.Data memory md = _makeData(name);
        md.label = "wrong";
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(LibMigration.NameDataMismatch.selector, node)
            )
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(node),
            1,
            abi.encode(md)
        );
    }

    function test_migrate_nameNotLocked() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
        bytes32 node = NameCoder.namehash(name, 0);
        LibMigration.Data memory md = _makeData(name);
        vm.expectRevert(
            WrappedErrorLib.wrap(abi.encodeWithSelector(LibMigration.NameNotLocked.selector, node))
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(node),
            1,
            abi.encode(md)
        );
    }

    function test_migrate_notReserved() external {
        premigrationController = address(0); // disable premigration
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        LibMigration.Data memory md = _makeData(name);
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(
                    IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                    ethRegistry.ROOT_RESOURCE(),
                    RegistryRolesLib.ROLE_REGISTRAR,
                    address(migrationController)
                )
            )
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );
    }

    function test_migrate() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        checkResolution(name, address(ensV2Resolver), address(ensV1Resolver));
        LibMigration.Data memory md = _makeData(name);
        bytes32 node = NameCoder.namehash(name, 0);
        uint256 salt = uint256(node);
        address expectedRegistry = _computeVerifiableFactoryAddress(
            address(migrationController),
            salt
        );
        uint256 tokenIdV1 = LibLabel.id(md.label);
        uint256 tokenId = LibLabel.withVersion(tokenIdV1, 0);
        vm.expectEmit();
        emit IERC1155.TransferSingle(user, user, address(migrationController), uint256(node), 1);
        vm.expectEmit();
        emit ENS.NewResolver(node, address(0));
        // emit IERC1967.Upgraded()
        vm.expectEmit();
        emit IEnhancedAccessControl.EACRolesChanged(
            0,
            /*ROOT_RESOURCE*/
            md.owner,
            0,
            /*old roles*/
            RegistryRolesLib.ROLE_UPGRADE_ADMIN |
                RegistryRolesLib.ROLE_UPGRADE |
                RegistryRolesLib.ROLE_REGISTRAR |
                RegistryRolesLib.ROLE_REGISTRAR_ADMIN |
                RegistryRolesLib.ROLE_RENEW |
                RegistryRolesLib.ROLE_RENEW_ADMIN
        );
        // emit Initializable.Initialized()
        vm.expectEmit();
        emit VerifiableFactory.ProxyDeployed(
            address(migrationController),
            expectedRegistry,
            salt,
            address(wrapperRegistryImpl)
        );
        vm.expectEmit();
        emit IRegistryEvents.LabelRegistered(
            tokenId,
            bytes32(tokenIdV1),
            md.label,
            md.owner,
            uint64(ethRegistrarV1.nameExpires(tokenIdV1)),
            address(migrationController)
        );
        vm.expectEmit();
        emit IERC1155.TransferSingle(
            address(migrationController),
            address(0),
            md.owner,
            tokenId,
            1
        );
        vm.expectEmit();
        emit IPermissionedRegistry.TokenResource(tokenId, tokenId);
        vm.expectEmit();
        emit IEnhancedAccessControl.EACRolesChanged(
            tokenId,
            md.owner,
            0,
            /*old roles*/
            RegistryRolesLib.ROLE_SET_RESOLVER |
                RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN |
                RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN
        );
        vm.expectEmit();
        emit IRegistryEvents.SubregistryUpdated(
            tokenId,
            IRegistry(expectedRegistry),
            address(migrationController)
        );
        vm.expectEmit();
        emit IRegistryEvents.ResolverUpdated(tokenId, md.resolver, address(migrationController));
        vm.prank(user);
        uint256 g = gasleft();
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );
        console.log("Gas: %s", g - gasleft());

        assertEq(ethRegistry.getTokenId(tokenIdV1), tokenId, "tokenId");
        assertEq(ethRegistry.ownerOf(tokenId), md.owner, "owner");
        assertEq(ethRegistry.getExpiry(tokenId), ethRegistrarV1.nameExpires(tokenIdV1), "expiry");
        assertEq(ethRegistry.getResolver(md.label), md.resolver, "resolver");
        checkResolution(name, address(ensV2Resolver), md.resolver);
        IWrapperRegistry subregistry = IWrapperRegistry(
            address(ethRegistry.getSubregistry(md.label))
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(subregistry),
                type(IWrapperRegistry).interfaceId
            ),
            "IWrapperRegistry"
        );
        assertTrue(
            subregistry.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, md.owner),
            "ROLE_REGISTRAR"
        );
        assertEq(subregistry.roleCount(RegistryRolesLib.ROLE_SET_PARENT), 0, "ROLE_SET_PARENT");
        assertEq(subregistry.getWrappedNode(), node, "getWrappedNode");
        assertEq(subregistry.getWrappedName(), name, "getWrappedName");
        assertEq(universalResolver.findCanonicalName(subregistry), name, "findCanonicalName");
    }

    function test_migrateBatch(uint8 count) external {
        vm.assume(count < 5);
        uint256[] memory ids = new uint256[](count);
        uint256[] memory amounts = new uint256[](count);
        LibMigration.Data[] memory mds = new LibMigration.Data[](count);
        for (uint256 i; i < count; ++i) {
            bytes memory name = registerWrappedETH2LD(_label(i), CANNOT_UNWRAP);
            LibMigration.Data memory md = _makeData(name);
            md.resolver = address(uint160(i));
            mds[i] = md;
            ids[i] = uint256(NameCoder.namehash(name, 0));
            amounts[i] = 1;
        }
        vm.prank(user);
        nameWrapper.safeBatchTransferFrom(
            user,
            address(migrationController),
            ids,
            amounts,
            abi.encode(mds)
        );
        for (uint256 i; i < count; ++i) {
            string memory label = _label(i);
            uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(label));
            assertEq(ethRegistry.ownerOf(tokenId), user, "owner");
            assertEq(ethRegistry.getResolver(label), address(uint160(i)), "resolver");
            assertTrue(
                ERC165Checker.supportsInterface(
                    address(ethRegistry.getSubregistry(label)),
                    type(IWrapperRegistry).interfaceId
                ),
                "IWrapperRegistry"
            );
        }
    }

    function test_migrateBatch_lastOneWrong(uint8 count) external {
        vm.assume(count > 1 && count < 5);
        uint256[] memory ids = new uint256[](count);
        uint256[] memory amounts = new uint256[](count);
        LibMigration.Data[] memory mds = new LibMigration.Data[](count);
        for (uint256 i; i < count; ++i) {
            bytes memory name = registerWrappedETH2LD(
                _label(i),
                i == count - 1 ? CAN_DO_EVERYTHING : CANNOT_UNWRAP
            );
            LibMigration.Data memory md = _makeData(name);
            mds[i] = md;
            ids[i] = uint256(NameCoder.namehash(name, 0));
            amounts[i] = 1;
        }
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(LibMigration.NameNotLocked.selector, ids[count - 1])
            )
        );
        vm.prank(user);
        nameWrapper.safeBatchTransferFrom(
            user,
            address(migrationController),
            ids,
            amounts,
            abi.encode(mds)
        );
    }

    function test_migrate_lockedResolver() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
        bytes32 node = NameCoder.namehash(name, 0);
        LibMigration.Data memory md = _makeData(name);

        address frozenResolver = makeAddr("frozenResolver");
        vm.prank(user);
        nameWrapper.setResolver(node, frozenResolver);
        vm.prank(user);
        nameWrapper.setFuses(node, uint16(CANNOT_UNWRAP | CANNOT_SET_RESOLVER));
        assertNotEq(md.resolver, frozenResolver, "diff");

        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(node),
            1,
            abi.encode(md)
        );

        uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(md.label));
        assertEq(ethRegistry.getResolver(md.label), frozenResolver, "frozen");
        checkResolution(name, frozenResolver, frozenResolver);
        assertFalse(ethRegistry.hasRoles(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, user));
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                tokenId,
                RegistryRolesLib.ROLE_SET_RESOLVER,
                user
            )
        );
        vm.prank(user);
        ethRegistry.setResolver(tokenId, testResolver);
    }

    function test_migrate_lockedTransfer() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP | CANNOT_TRANSFER);
        bytes32 node = NameCoder.namehash(name, 0);
        LibMigration.Data memory md = _makeData(name);

        vm.expectRevert(abi.encodeWithSelector(OperationProhibited.selector, node));
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(node),
            1,
            abi.encode(md)
        );
    }

    function test_migrate_lockedFuses() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP | CANNOT_BURN_FUSES);
        LibMigration.Data memory md = _makeData(name);

        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );

        uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(md.label));
        assertEq(
            ethRegistry.roles(tokenId, user) & EACBaseRolesLib.ADMIN_ROLES,
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN,
            "token"
        );
        IWrapperRegistry registry = IWrapperRegistry(address(ethRegistry.getSubregistry(md.label)));
        assertEq(
            registry.roles(registry.ROOT_RESOURCE(), user) & EACBaseRolesLib.ADMIN_ROLES,
            RegistryRolesLib.ROLE_UPGRADE_ADMIN | RegistryRolesLib.ROLE_RENEW_ADMIN,
            "registry"
        );
    }

    function test_migrate_lockedChildren() external {
        bytes memory name = registerWrappedETH2LD(
            testLabel,
            CANNOT_UNWRAP | CANNOT_CREATE_SUBDOMAIN
        );
        LibMigration.Data memory md = _makeData(name);

        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );

        uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(md.label));
        assertFalse(ethRegistry.hasRoles(tokenId, RegistryRolesLib.ROLE_REGISTRAR, user));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                ethRegistry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_REGISTRAR,
                user
            )
        );
        vm.prank(user);
        ethRegistry.register(
            string.concat(testLabel, testLabel),
            user,
            IRegistry(address(0)),
            address(0),
            0,
            _soon()
        );
    }

    function test_migrate_canExtendExpiry() external {
        bytes memory name2 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(
            name2,
            "sub",
            friend,
            CANNOT_UNWRAP | PARENT_CANNOT_CONTROL | CAN_EXTEND_EXPIRY
        );

        // migrate 2LD
        LibMigration.Data memory data2 = _makeData(name2);
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name2, 0)),
            1,
            abi.encode(data2)
        );
        IWrapperRegistry registry2 = IWrapperRegistry(
            address(ethRegistry.getSubregistry(data2.label))
        );

        // migrate 3LD
        LibMigration.Data memory data3 = _makeData(name3);
        vm.prank(friend);
        nameWrapper.safeTransferFrom(
            friend,
            address(registry2),
            uint256(NameCoder.namehash(name3, 0)),
            1,
            abi.encode(data3)
        );

        uint256 tokenId = registry2.getTokenId(LibLabel.id(data3.label));
        assertTrue(registry2.hasRoles(tokenId, RegistryRolesLib.ROLE_RENEW, friend), "ROLE_RENEW");

        uint64 expiry = registry2.getExpiry(tokenId);
        vm.prank(friend);
        registry2.renew(tokenId, expiry + 1);
    }

    function test_migrate_emancipatedChildren() external {
        bytes memory name2 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes memory name3 = createWrappedChild(
            name2,
            "sub",
            friend,
            CANNOT_UNWRAP | PARENT_CANNOT_CONTROL
        );
        bytes memory name3unmigrated = createWrappedChild(
            name2,
            "unmigrated",
            friend,
            CANNOT_UNWRAP | PARENT_CANNOT_CONTROL
        );

        // migrate 2LD
        LibMigration.Data memory data2 = _makeData(name2);
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name2, 0)),
            1,
            abi.encode(data2)
        );
        assertEq(
            ethRegistry.ownerOf(ethRegistry.getTokenId(LibLabel.id(data2.label))),
            data2.owner,
            "owner2"
        );
        IWrapperRegistry registry2 = IWrapperRegistry(
            address(ethRegistry.getSubregistry(data2.label))
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(registry2), type(IWrapperRegistry).interfaceId),
            "registry2"
        );

        // migrate 3LD
        LibMigration.Data memory data3 = _makeData(name3);
        vm.prank(friend);
        nameWrapper.safeTransferFrom(
            friend,
            address(registry2),
            uint256(NameCoder.namehash(name3, 0)),
            1,
            abi.encode(data3)
        );
        assertEq(registry2.getResolver(data3.label), data3.resolver, "resolver3");
        checkResolution(name3, address(ensV2Resolver), data3.resolver);
        assertEq(
            registry2.ownerOf(registry2.getTokenId(LibLabel.id(data3.label))),
            data3.owner,
            "owner3"
        );
        IRegistry registry3 = registry2.getSubregistry(data3.label);
        assertTrue(
            ERC165Checker.supportsInterface(address(registry3), type(IWrapperRegistry).interfaceId),
            "registry3"
        );

        // check migrated 3LD child
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.LabelAlreadyRegistered.selector, data3.label)
        );
        vm.prank(friend);
        registry2.register(data3.label, user, IRegistry(address(0)), address(0), 0, _soon());

        // check unmigrated 3LD child
        vm.expectRevert(abi.encodeWithSelector(LibMigration.NameRequiresMigration.selector));
        vm.prank(friend);
        registry2.register(
            NameCoder.firstLabel(name3unmigrated),
            friend,
            IRegistry(address(0)),
            address(0),
            0,
            _soon()
        );

        vm.prank(friend);
        nameWrapper.setResolver(NameCoder.namehash(name3unmigrated, 0), testResolver);
        checkResolution(name3unmigrated, testResolver, address(ensV1Resolver));
    }

    function test_migrate_frozenTokenApproval() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes32 node = NameCoder.namehash(name, 0);

        // give approval
        vm.prank(user);
        nameWrapper.approve(address(this), uint256(node));
        assertEq(nameWrapper.getApproved(uint256(node)), address(this), "approved");

        // freeze approval
        vm.prank(user);
        nameWrapper.setFuses(node, uint16(CANNOT_APPROVE));

        LibMigration.Data memory data = _makeData(name);
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(LibMigration.FrozenTokenApproval.selector, node)
            )
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(node),
            1,
            abi.encode(data)
        );
    }

    function _makeData(bytes memory name) internal view returns (LibMigration.Data memory) {
        return
            LibMigration.Data({
                label: NameCoder.firstLabel(name),
                owner: nameWrapper.ownerOf(uint256(NameCoder.namehash(name, 0))),
                subregistry: IRegistry(address(0)), // ignored by LockedMigrationController
                resolver: testResolver
            });
    }
}
