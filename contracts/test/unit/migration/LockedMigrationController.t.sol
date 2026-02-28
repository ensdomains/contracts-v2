// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Vm, console} from "forge-std/Test.sol";
import {
    INameWrapper,
    OperationProhibited,
    CANNOT_UNWRAP,
    CAN_DO_EVERYTHING,
    CANNOT_BURN_FUSES,
    CANNOT_TRANSFER,
    CANNOT_SET_RESOLVER,
    CANNOT_SET_TTL,
    CANNOT_CREATE_SUBDOMAIN,
    PARENT_CANNOT_CONTROL,
    IS_DOT_ETH,
    CAN_EXTEND_EXPIRY
} from "@ens/contracts/wrapper/NameWrapper.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC1155, IERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {UnauthorizedCaller} from "~src/CommonErrors.sol";
import {ENSV1Resolver} from "~src/resolver/ENSV1Resolver.sol";
import {V1Fixture, ENS} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture, VerifiableFactory} from "~test/fixtures/V2Fixture.sol";
import {WrappedErrorLib} from "~src/utils/WrappedErrorLib.sol";
import {
    LockedMigrationController,
    IPermissionedRegistry
} from "~src/migration/LockedMigrationController.sol";
import {
    IEnhancedAccessControl,
    EACBaseRolesLib
} from "~src/access-control/EnhancedAccessControl.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {
    WrapperRegistry,
    IWrapperRegistry,
    IStandardRegistry,
    UUPSUpgradeable,
    WrapperReceiver,
    RegistryRolesLib,
    MigrationErrors,
    IRegistry
} from "~src/registry/WrapperRegistry.sol";

contract LockedMigrationControllerTest is V1Fixture, V2Fixture {
    LockedMigrationController migrationController;
    WrapperRegistry wrapperRegistryImpl;
    ENSV1Resolver ensV1Resolver;
    MockERC1155 dummy1155;

    string testLabel = "test";
    address premigrationController = makeAddr("premigrationController");

    function setUp() external {
        deployV1Fixture();
        deployV2Fixture();
        dummy1155 = new MockERC1155();
        ensV1Resolver = new ENSV1Resolver(ensV1, batchGatewayProvider);
        wrapperRegistryImpl = new WrapperRegistry(
            nameWrapper,
            verifiableFactory,
            address(ensV1Resolver),
            hcaFactory,
            metadata
        );
        migrationController = new LockedMigrationController(
            ethRegistry,
            nameWrapper,
            verifiableFactory,
            address(wrapperRegistryImpl)
        );
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, premigrationController);
        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(migrationController)
        );
    }

    function _makeData(bytes memory name) internal view returns (IWrapperRegistry.Data memory) {
        return
            IWrapperRegistry.Data({
                label: NameCoder.firstLabel(name),
                owner: user,
                resolver: address(1),
                salt: uint256(keccak256(abi.encode(name, block.timestamp)))
            });
    }

    function test_constructor() external view {
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
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(
                address(migrationController),
                type(IERC165).interfaceId
            ),
            "IERC165"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(migrationController),
                type(IERC1155Receiver).interfaceId
            ),
            "IERC1155Receiver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(migrationController),
                type(WrapperReceiver).interfaceId
            ),
            "WrapperReceiver"
        );
    }

    function test_migrate_unauthorizedCaller_finish() external {
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, user));
        vm.prank(user);
        migrationController.finishERC1155Migration(
            new uint256[](0),
            new IWrapperRegistry.Data[](0)
        );
    }

    function test_migrate_unauthorizedCaller_transfer() external {
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
            WrappedErrorLib.wrap(abi.encodeWithSelector(IWrapperRegistry.InvalidData.selector))
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
        IWrapperRegistry.Data[] memory mds = new IWrapperRegistry.Data[](1);
        ids[0] = uint256(NameCoder.namehash(name, 0));
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

    function test_migrate_invalidReceiver() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        IWrapperRegistry.Data memory md = _makeData(name);
        md.owner = address(0);
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
        IWrapperRegistry.Data memory md = _makeData(name);
        md.label = "wrong";
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(MigrationErrors.NameDataMismatch.selector, node)
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
        IWrapperRegistry.Data memory md = _makeData(name);
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(MigrationErrors.NameNotLocked.selector, node)
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

    function test_migrate_notReserved() external {
        premigrationController = address(0); // disable premigration
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        IWrapperRegistry.Data memory md = _makeData(name);
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
        IWrapperRegistry.Data memory md = _makeData(name);

        bytes32 node = NameCoder.namehash(name, 0);
        address expectedRegistry = _computeVerifiableFactoryAddress(
            address(migrationController),
            md.salt
        );
        uint256 tokenId = LibLabel.withVersion(LibLabel.id(testLabel), 0);
        vm.expectEmit();
        emit IERC1155.TransferSingle(user, user, address(migrationController), uint256(node), 1);
        vm.expectEmit();
        emit ENS.NewResolver(node, address(0));
        // emit IERC1967.Upgraded()
        vm.expectEmit();
        emit IEnhancedAccessControl.EACRolesChanged(
            0 /*ROOT_RESOURCE*/,
            md.owner,
            0 /*old roles*/,
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
            md.salt,
            address(wrapperRegistryImpl)
        );
        // emit IRegistry.NameRegistered()
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
            0 /*old roles*/,
            RegistryRolesLib.ROLE_SET_RESOLVER |
                RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN |
                RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN
        );
        vm.expectEmit();
        emit IRegistry.SubregistryUpdated(
            tokenId,
            IRegistry(expectedRegistry),
            address(migrationController)
        );
        vm.expectEmit();
        emit IRegistry.ResolverUpdated(tokenId, md.resolver, address(migrationController));
        vm.expectEmit();
        emit INameWrapper.FusesSet(
            node,
            CANNOT_UNWRAP |
                CANNOT_BURN_FUSES |
                CANNOT_TRANSFER |
                CANNOT_SET_RESOLVER |
                CANNOT_CREATE_SUBDOMAIN |
                CANNOT_SET_TTL |
                IS_DOT_ETH |
                PARENT_CANNOT_CONTROL
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );

        assertEq(ethRegistry.getTokenId(LibLabel.id(testLabel)), tokenId, "tokenId");
        assertEq(ethRegistry.ownerOf(tokenId), md.owner, "owner");
        assertEq(ethRegistry.getResolver(testLabel), md.resolver, "resolver");
        assertEq(
            ethRegistry.getExpiry(tokenId),
            ethRegistrarV1.nameExpires(LibLabel.id(testLabel)),
            "expiry"
        );
        WrapperRegistry subregistry = WrapperRegistry(
            address(ethRegistry.getSubregistry(testLabel))
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(subregistry),
                type(IWrapperRegistry).interfaceId
            ),
            "IWrapperRegistry"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(subregistry),
                type(WrapperReceiver).interfaceId
            ),
            "WrapperReceiver"
        );
        assertTrue(
            subregistry.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, md.owner),
            "ROLE_REGISTRAR"
        );
        assertEq(address(subregistry.NAME_WRAPPER()), address(nameWrapper), "NAME_WRAPPER");
        assertEq(
            address(subregistry.VERIFIABLE_FACTORY()),
            address(verifiableFactory),
            "VERIFIABLE_FACTORY"
        );
        assertEq(
            subregistry.WRAPPER_REGISTRY_IMPL(),
            address(wrapperRegistryImpl),
            "WRAPPER_REGISTRY_IMPL"
        );
    }

    function test_migrateBatch(uint8 count) external {
        vm.assume(count < 5);
        uint256[] memory ids = new uint256[](count);
        uint256[] memory amounts = new uint256[](count);
        IWrapperRegistry.Data[] memory mds = new IWrapperRegistry.Data[](count);
        for (uint256 i; i < count; ++i) {
            bytes memory name = registerWrappedETH2LD(_label(i), CANNOT_UNWRAP);
            IWrapperRegistry.Data memory md = _makeData(name);
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
        IWrapperRegistry.Data[] memory mds = new IWrapperRegistry.Data[](count);
        for (uint256 i; i < count; ++i) {
            bytes memory name = registerWrappedETH2LD(
                _label(i),
                i == count - 1 ? CAN_DO_EVERYTHING : CANNOT_UNWRAP
            );
            IWrapperRegistry.Data memory md = _makeData(name);
            mds[i] = md;
            ids[i] = uint256(NameCoder.namehash(name, 0));
            amounts[i] = 1;
        }
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(MigrationErrors.NameNotLocked.selector, ids[count - 1])
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
        IWrapperRegistry.Data memory md = _makeData(name);

        address frozenResolver = address(2);
        vm.startPrank(user);
        nameWrapper.setResolver(node, frozenResolver);
        nameWrapper.setFuses(node, uint16(CANNOT_UNWRAP | CANNOT_SET_RESOLVER));
        vm.stopPrank();
        assertNotEq(md.resolver, frozenResolver, "diff");

        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(node),
            1,
            abi.encode(md)
        );

        uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(testLabel));
        assertEq(ethRegistry.getResolver(testLabel), frozenResolver, "frozen");
        assertEq(findResolverV2(name), frozenResolver, "findResolverV2");
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
        ethRegistry.setResolver(tokenId, address(1));
    }

    function test_migrate_lockedTransfer() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP | CANNOT_TRANSFER);
        bytes32 node = NameCoder.namehash(name, 0);
        IWrapperRegistry.Data memory md = _makeData(name);

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

    function test_migrate_lockedExpiry() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP | CAN_EXTEND_EXPIRY);
        IWrapperRegistry.Data memory md = _makeData(name);

        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );

        uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(testLabel));
        assertFalse(ethRegistry.hasRoles(tokenId, RegistryRolesLib.ROLE_RENEW, user));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                tokenId,
                RegistryRolesLib.ROLE_RENEW,
                user
            )
        );
        vm.prank(user);
        ethRegistry.renew(tokenId, _soon());
    }

    function test_migrate_lockedChildren() external {
        bytes memory name = registerWrappedETH2LD(
            testLabel,
            CANNOT_UNWRAP | CANNOT_CREATE_SUBDOMAIN
        );
        IWrapperRegistry.Data memory md = _makeData(name);

        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );

        uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(testLabel));
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

    function test_migrate_lockedFuses() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP | CANNOT_BURN_FUSES);
        IWrapperRegistry.Data memory md = _makeData(name);

        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1,
            abi.encode(md)
        );

        uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(testLabel));
        assertEq(
            ethRegistry.roles(tokenId, user) & EACBaseRolesLib.ADMIN_ROLES,
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN,
            "token"
        );
        IWrapperRegistry registry = IWrapperRegistry(
            address(ethRegistry.getSubregistry(testLabel))
        );
        assertEq(
            registry.roles(registry.ROOT_RESOURCE(), user) & EACBaseRolesLib.ADMIN_ROLES,
            RegistryRolesLib.ROLE_UPGRADE_ADMIN | RegistryRolesLib.ROLE_RENEW_ADMIN,
            "registry"
        );
    }

    function test_migrate_emancipatedChildren() external {
        bytes memory name2 = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        string memory label3 = "sub";
        bytes memory name3 = createWrappedChild(
            name2,
            label3,
            CANNOT_UNWRAP | PARENT_CANNOT_CONTROL
        );
        bytes memory name3unmigrated = createWrappedChild(
            name2,
            "unmigrated",
            CANNOT_UNWRAP | PARENT_CANNOT_CONTROL
        );

        // migrate 2LD
        IWrapperRegistry.Data memory data2 = _makeData(name2);
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name2, 0)),
            1,
            abi.encode(data2)
        );
        assertEq(
            ethRegistry.ownerOf(ethRegistry.getTokenId(LibLabel.id(testLabel))),
            data2.owner,
            "owner2"
        );
        IWrapperRegistry registry2 = IWrapperRegistry(
            address(ethRegistry.getSubregistry(testLabel))
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(registry2), type(IWrapperRegistry).interfaceId),
            "registry2"
        );

        // migrate 3LD
        IWrapperRegistry.Data memory data3 = _makeData(name3);
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(registry2),
            uint256(NameCoder.namehash(name3, 0)),
            1,
            abi.encode(data3)
        );
        assertEq(registry2.getResolver(label3), data3.resolver, "resolver3");
        assertEq(findResolverV2(name3), data3.resolver, "findResolver3");
        assertEq(
            registry2.ownerOf(registry2.getTokenId(LibLabel.id(label3))),
            data3.owner,
            "owner3"
        );
        IRegistry registry3 = registry2.getSubregistry(label3);
        assertTrue(
            ERC165Checker.supportsInterface(address(registry3), type(IWrapperRegistry).interfaceId),
            "registry3"
        );

        // check migrated 3LD child
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.NameAlreadyRegistered.selector, label3)
        );
        vm.prank(user);
        registry2.register(label3, user, IRegistry(address(0)), address(0), 0, _soon());

        // check unmigrated 3LD child
        vm.expectRevert(abi.encodeWithSelector(MigrationErrors.NameRequiresMigration.selector));
        vm.prank(user);
        registry2.register(
            NameCoder.firstLabel(name3unmigrated),
            user,
            IRegistry(address(0)),
            address(0),
            0,
            _soon()
        );
        assertEq(findResolverV2(name3unmigrated), address(ensV1Resolver), "unmigratedResolver");
    }

    /// @dev Ensure premigration has occurred.
    function registerWrappedETH2LD(
        string memory label,
        uint32 flags
    ) public override returns (bytes memory name) {
        name = super.registerWrappedETH2LD(label, flags);
        if (address(premigrationController) != address(0)) {
            vm.prank(premigrationController);
            ethRegistry.register(
                label,
                address(0), // reserve
                IRegistry(address(0)),
                address(ensV1Resolver),
                0,
                uint64(ethRegistrarV1.nameExpires(LibLabel.id(label)))
            );
        }
    }

    function _label(uint256 i) internal view returns (string memory) {
        return string.concat(testLabel, vm.toString(i));
    }

    function _soon() internal view returns (uint64) {
        return uint64(block.timestamp + 1000);
    }
}

contract MockERC1155 is ERC1155 {
    uint256 _id;
    constructor() ERC1155("") {}
    function mint(address to) external returns (uint256) {
        _mint(to, _id, 1, "");
        return _id++;
    }
}
