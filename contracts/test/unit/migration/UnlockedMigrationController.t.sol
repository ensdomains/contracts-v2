// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {console} from "forge-std/console.sol";
import {
    INameWrapper,
    CAN_DO_EVERYTHING,
    CANNOT_UNWRAP
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {WrappedErrorLib} from "~src/utils/WrappedErrorLib.sol";
import {
    IEnhancedAccessControl,
    EACBaseRolesLib
} from "~src/access-control/EnhancedAccessControl.sol";
import {
    PermissionedRegistry,
    IPermissionedRegistry,
    RegistryRolesLib,
    IRegistry,
    IRegistryMetadata,
    LibLabel
} from "~src/registry/PermissionedRegistry.sol";
import {
    UnlockedMigrationController,
    LibMigration,
    InvalidOwner,
    UnauthorizedCaller
} from "~src/migration/UnlockedMigrationController.sol";
import {
    MigrationControllerFixture,
    ERC165Checker,
    NameCoder
} from "./MigrationControllerFixture.sol";
import {V1Fixture, ENS} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract UnlockedMigrationControllerTest is MigrationControllerFixture {
    UnlockedMigrationController migrationController;

    function setUp() public override {
        super.setUp();
        migrationController = new UnlockedMigrationController(nameWrapper, ethRegistry);
        ethRegistry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, premigrationController);
        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(migrationController)
        );
    }

    function test_constructor() external view {
        assertEq(address(migrationController.ETH_REGISTRY()), address(ethRegistry), "ETH_REGISTRY");
        assertEq(address(migrationController.NAME_WRAPPER()), address(nameWrapper), "NAME_WRAPPER");
    }

    function test_supportsInterface() external view {
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
                type(IERC721Receiver).interfaceId
            ),
            "IERC721Receiver"
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

    function test_unwrapped_invalidData() external {
        (, uint256 tokenIdV1) = registerUnwrapped(testLabel);
        vm.expectRevert(abi.encodeWithSelector(LibMigration.InvalidData.selector));
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(
            user,
            address(migrationController),
            tokenIdV1,
            "" // wrong
        );
    }

    function test_wrapped_invalidData() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
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

    function test_wrapped_invalidArrayLength() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
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

    function test_unwrapped_invalidOwner() external {
        (bytes memory name, uint256 tokenIdV1) = registerUnwrapped(testLabel);
        LibMigration.Data memory md = _makeData(name);
        md.owner = address(0); // wrong
        vm.expectRevert(abi.encodeWithSelector(InvalidOwner.selector));
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(
            user,
            address(migrationController),
            tokenIdV1,
            abi.encode(md)
        );
    }

    function test_wrapped_invalidOwner() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
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

    function test_unwrapped_invalidReceiver() external {
        (bytes memory name, uint256 tokenIdV1) = registerUnwrapped(testLabel);
        LibMigration.Data memory md = _makeData(name);
        md.owner = address(ethRegistry); // not a IERC1155Receiver

        vm.expectRevert(
            abi.encodeWithSelector(IERC1155Errors.ERC1155InvalidReceiver.selector, md.owner)
        );
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(
            user,
            address(migrationController),
            tokenIdV1,
            abi.encode(md)
        );
    }

    function test_wrapped_invalidReceiver() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
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

    function test_wrapped_nameDataMismatch() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
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

    function test_wrapped_nameIsLocked() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CANNOT_UNWRAP);
        bytes32 node = NameCoder.namehash(name, 0);
        LibMigration.Data memory md = _makeData(name);
        vm.expectRevert(
            WrappedErrorLib.wrap(abi.encodeWithSelector(LibMigration.NameIsLocked.selector, node))
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

    function test_unwrapped_notReserved() external {
        premigrationController = address(0); // disable premigration
        (bytes memory name, uint256 tokenIdV1) = registerUnwrapped(testLabel);
        LibMigration.Data memory md = _makeData(name);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                ethRegistry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_REGISTRAR,
                address(migrationController)
            )
        );
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(
            user,
            address(migrationController),
            tokenIdV1,
            abi.encode(md)
        );
    }

    function test_wrapped_notReserved() external {
        premigrationController = address(0); // disable premigration
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
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

    function test_unwrapped_migrate() external {
        (bytes memory name, uint256 tokenIdV1) = registerUnwrapped(testLabel);
        LibMigration.Data memory md = _makeData(name);
        uint256 tokenId = LibLabel.withVersion(tokenIdV1, 0);
        vm.expectEmit();
        emit IERC721.Transfer(user, address(migrationController), tokenIdV1);
        vm.expectEmit();
        emit IRegistry.NameRegistered(
            tokenId,
            keccak256(bytes(md.label)),
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
        emit IRegistry.SubregistryUpdated(
            tokenId,
            IRegistry(md.subregistry),
            address(migrationController)
        );
        vm.expectEmit();
        emit IRegistry.ResolverUpdated(tokenId, md.resolver, address(migrationController));
        vm.prank(user);
        uint256 g = gasleft();
        ethRegistrarV1.safeTransferFrom(
            user,
            address(migrationController),
            tokenIdV1,
            abi.encode(md)
        );
        console.log("Gas: %s", g - gasleft());

        assertEq(ethRegistry.getTokenId(tokenIdV1), tokenId, "tokenId");
        assertEq(ethRegistry.ownerOf(tokenId), md.owner, "owner");
        assertEq(ethRegistry.getExpiry(tokenId), ethRegistrarV1.nameExpires(tokenIdV1), "expiry");
        assertEq(ethRegistry.getResolver(md.label), md.resolver, "resolver");
        checkResolution(name, address(ensV2Resolver), md.resolver);
        assertEq(
            address(ethRegistry.getSubregistry(md.label)),
            address(md.subregistry),
            "subregistry"
        );
        assertEq(registryV1.resolver(NameCoder.namehash(name, 0)), address(0), "resolverV1");
    }

    function test_wrapped_migrate() external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
        LibMigration.Data memory md = _makeData(name);
        uint256 tokenIdV1 = uint256(keccak256(bytes(md.label)));
        uint256 tokenId = LibLabel.withVersion(tokenIdV1, 0);
        vm.expectEmit();
        emit IERC1155.TransferSingle(
            user,
            user,
            address(migrationController),
            uint256(NameCoder.namehash(name, 0)),
            1
        );
        vm.expectEmit();
        emit IRegistry.NameRegistered(
            tokenId,
            keccak256(bytes(md.label)),
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
        emit IRegistry.SubregistryUpdated(
            tokenId,
            IRegistry(md.subregistry),
            address(migrationController)
        );
        vm.expectEmit();
        emit IRegistry.ResolverUpdated(tokenId, md.resolver, address(migrationController));
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
        assertEq(
            address(ethRegistry.getSubregistry(md.label)),
            address(md.subregistry),
            "subregistry"
        );
    }

    function test_unwrapped_migrateViaApproval(bool all) external {
        (bytes memory name, uint256 tokenIdV1) = registerUnwrapped(testLabel);
        LibMigration.Data memory md = _makeData(name);

        // give friend approval
        vm.prank(user);
        if (all) {
            ethRegistrarV1.setApprovalForAll(friend, true);
        } else {
            ethRegistrarV1.approve(friend, tokenIdV1);
        }

        // friend initiates migration
        vm.prank(friend);
        ethRegistrarV1.safeTransferFrom(
            user,
            address(migrationController),
            tokenIdV1,
            abi.encode(md)
        );

        uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(md.label));
        assertEq(ethRegistry.ownerOf(tokenId), md.owner, "owner");
    }

    function test_wrapped_migrateViaApproval(/* bool all */) external {
        bytes memory name = registerWrappedETH2LD(testLabel, CAN_DO_EVERYTHING);
        LibMigration.Data memory md = _makeData(name);
        bytes32 node = NameCoder.namehash(name, 0);

        // give friend approval
        vm.prank(user);
        // if (all) {
        nameWrapper.setApprovalForAll(friend, true);
        // } else {
        //     nameWrapper.approve(friend, uint256(node));
        // }
        // see: V1Fixture.t.sol: `test_nameWrapper_approveBug()`

        // friend initiates migration
        vm.prank(friend);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(node),
            1,
            abi.encode(md)
        );

        uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(md.label));
        assertEq(ethRegistry.ownerOf(tokenId), md.owner, "owner");
    }

    function test_wrapped_migrateBatch(uint8 count) external {
        vm.assume(count < 5);
        uint256[] memory ids = new uint256[](count);
        uint256[] memory amounts = new uint256[](count);
        LibMigration.Data[] memory mds = new LibMigration.Data[](count);
        for (uint256 i; i < count; ++i) {
            bytes memory name = registerWrappedETH2LD(_label(i), CAN_DO_EVERYTHING);
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
            LibMigration.Data memory md = mds[i];
            uint256 tokenId = ethRegistry.getTokenId(LibLabel.id(md.label));
            assertEq(ethRegistry.ownerOf(tokenId), md.owner, "owner");
            assertEq(
                ethRegistry.getExpiry(tokenId),
                ethRegistrarV1.nameExpires(uint256(keccak256(bytes(md.label)))),
                "expiry"
            );
            assertEq(ethRegistry.getResolver(md.label), md.resolver, "resolver");
            checkResolution(
                NameCoder.ethName(md.label),
                address(ensV2Resolver),
                address(uint160(i))
            );
            assertEq(
                address(ethRegistry.getSubregistry(md.label)),
                address(md.subregistry),
                "subregistry"
            );
        }
    }

    function test_wrapped_migrateBatch_lastOneWrong(uint8 count) external {
        vm.assume(count > 1 && count < 5);
        uint256[] memory ids = new uint256[](count);
        uint256[] memory amounts = new uint256[](count);
        LibMigration.Data[] memory mds = new LibMigration.Data[](count);
        for (uint256 i; i < count; ++i) {
            bytes memory name = registerWrappedETH2LD(
                _label(i),
                i == count - 1 ? CANNOT_UNWRAP : CAN_DO_EVERYTHING
            );
            LibMigration.Data memory md = _makeData(name);
            mds[i] = md;
            ids[i] = uint256(NameCoder.namehash(name, 0));
            amounts[i] = 1;
        }
        vm.expectRevert(
            WrappedErrorLib.wrap(
                abi.encodeWithSelector(LibMigration.NameIsLocked.selector, ids[count - 1])
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

    function _makeData(bytes memory name) internal view returns (LibMigration.Data memory) {
        return
            LibMigration.Data({
                label: NameCoder.firstLabel(name),
                owner: user,
                subregistry: testRegistry,
                resolver: testResolver
            });
    }
}
