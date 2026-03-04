// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Vm} from "forge-std/Test.sol";
import {
    INameWrapper,
    CAN_DO_EVERYTHING,
    CANNOT_UNWRAP
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";

import {MigrationControllerFixture, ERC165Checker} from "./MigrationControllerFixture.sol";
import {V1Fixture, ENS} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";
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
    IERC1155Errors,
    UnauthorizedCaller
} from "~src/migration/UnlockedMigrationController.sol";

contract UnlockedMigrationControllerTest is MigrationControllerFixture {
    UnlockedMigrationController migrationController;

    function setUp() public override {
        super.setUp();
        migrationController = new UnlockedMigrationController(ethRegistry, nameWrapper);
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

    function test_unwrapped_invalidReceiver() external {
        (bytes memory name, uint256 tokenIdV1) = registerUnwrapped(testLabel);
        LibMigration.Data memory md = _makeData(name);
        md.owner = address(0); // wrong
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
        md.owner = address(0); // wrong
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
        emit IRegistry.SubregistryUpdated(
            tokenId,
            IRegistry(md.subregistry),
            address(migrationController)
        );
        vm.expectEmit();
        emit IRegistry.ResolverUpdated(tokenId, md.resolver, address(migrationController));
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(
            user,
            address(migrationController),
            tokenIdV1,
            abi.encode(md)
        );

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

    function test_clearRegistryV1() external {
        (bytes memory name1, uint256 tokenIdV1) = registerUnwrapped("unwrapped");
        bytes memory name2 = registerWrappedETH2LD("wrapped", CAN_DO_EVERYTHING);

        bytes32 node1 = NameCoder.namehash(name1, 0);
        bytes32 node2 = NameCoder.namehash(name2, 0);

        string memory childLabel = "abc";
        bytes32 childLabelHash = keccak256(bytes(childLabel));

        // set 3LD resolvers
        vm.prank(user);
        registryV1.setSubnodeRecord(node1, childLabelHash, user, address(1), 0);
        vm.prank(user);
        nameWrapper.setSubnodeRecord(node2, childLabel, user, address(2), 0, 0, 0);

        // migrate 2LD
        vm.prank(user);
        ethRegistrarV1.safeTransferFrom(
            user,
            address(migrationController),
            tokenIdV1,
            abi.encode(_makeData(name1))
        );
        vm.prank(user);
        nameWrapper.safeTransferFrom(
            user,
            address(migrationController),
            uint256(node2),
            1,
            abi.encode(_makeData(name2))
        );

        // confirm 3LD resolvers still exist
        assertEq(
            registryV1.resolver(NameCoder.namehash(node1, childLabelHash)),
            address(1),
            "before1"
        );
        assertEq(
            registryV1.resolver(NameCoder.namehash(node2, childLabelHash)),
            address(2),
            "before2"
        );

        // clear 3LD resolvers of migrated tokens
        bytes32[] memory parents = new bytes32[](2);
        bytes32[] memory labels = new bytes32[](2);
        parents[0] = node1;
        parents[1] = node2;
        labels[0] = childLabelHash;
        labels[1] = childLabelHash;
        migrationController.clearRegistryV1(parents, labels);

        assertEq(
            registryV1.resolver(NameCoder.namehash(node1, childLabelHash)),
            address(0),
            "after1"
        );
        assertEq(
            registryV1.resolver(NameCoder.namehash(node2, childLabelHash)),
            address(0),
            "after2"
        );
    }

    function _makeData(bytes memory name) internal view returns (LibMigration.Data memory) {
        return
            LibMigration.Data({
                label: NameCoder.firstLabel(name),
                owner: user,
                subregistry: testRegistry,
                resolver: testResolver,
                salt: 0 // ignored
            });
    }
}
