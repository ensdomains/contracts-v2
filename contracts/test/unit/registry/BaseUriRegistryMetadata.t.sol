// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {BaseUriRegistryMetadata} from "~src/registry/BaseUriRegistryMetadata.sol";
import {IRegistryMetadata} from "~src/registry/interfaces/IRegistryMetadata.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract BaseUriRegistryMetadataTest is Test, ERC1155Holder {
    MockHCAFactoryBasic hcaFactory;
    PermissionedRegistry registry;
    PermissionedRegistry parentRegistry;
    BaseUriRegistryMetadata metadata;

    uint256 constant ROLE_UPDATE_METADATA = 1 << 0;

    uint256 constant DEFAULT_ROLE_BITMAP =
        RegistryRolesLib.ROLE_SET_SUBREGISTRY | RegistryRolesLib.ROLE_SET_RESOLVER;

    uint256 constant ROOT_RESOURCE = 0;

    function setUp() public {
        hcaFactory = new MockHCAFactoryBasic();
        metadata = new BaseUriRegistryMetadata(hcaFactory);

        // Use the valid ALL_ROLES value for deployer roles
        uint256 deployerRoles = EACBaseRolesLib.ALL_ROLES;
        registry = new PermissionedRegistry(hcaFactory, metadata, address(this), deployerRoles);
    }

    function test_registry_metadata_base_uri() public {
        uint256 tokenId = uint256(keccak256(bytes("sub")));

        registry.register(
            "sub",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            uint64(block.timestamp + 1000)
        );

        assertEq(registry.uri(tokenId), "");

        string memory expectedUri = "ipfs://base/{id}";
        metadata.setTokenBaseUri(expectedUri);
        assertEq(metadata.tokenUri(tokenId), expectedUri);
        assertEq(registry.uri(tokenId), expectedUri);
    }

    function test_registry_metadata_base_uri_multiple_tokens() public {
        string memory expectedUri = "ipfs://base/{id}";
        uint256 tokenId1 = uint256(keccak256(bytes("sub1")));
        uint256 tokenId2 = uint256(keccak256(bytes("sub2")));

        registry.register(
            "sub1",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            uint64(block.timestamp + 1000)
        );
        registry.register(
            "sub2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            uint64(block.timestamp + 1000)
        );

        metadata.setTokenBaseUri(expectedUri);

        assertEq(metadata.tokenUri(tokenId1), expectedUri);
        assertEq(metadata.tokenUri(tokenId2), expectedUri);
        assertEq(registry.uri(tokenId1), expectedUri);
        assertEq(registry.uri(tokenId2), expectedUri);
    }

    function test_registry_metadata_base_uri_update() public {
        string memory initialUri = "ipfs://initial/{id}";
        string memory updatedUri = "ipfs://updated/{id}";
        uint256 tokenId = uint256(keccak256(bytes("sub")));

        registry.register(
            "sub",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            uint64(block.timestamp + 1000)
        );

        metadata.setTokenBaseUri(initialUri);
        assertEq(metadata.tokenUri(tokenId), initialUri);

        metadata.setTokenBaseUri(updatedUri);
        assertEq(metadata.tokenUri(tokenId), updatedUri);
    }

    function test_registry_metadata_unauthorized() public {
        string memory expectedUri = "ipfs://test/";

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                ROOT_RESOURCE,
                ROLE_UPDATE_METADATA,
                address(1)
            )
        );
        vm.prank(address(1));
        metadata.setTokenBaseUri(expectedUri);
    }

    function test_registry_metadata_supports_interface() public view {
        assertEq(metadata.supportsInterface(type(IRegistryMetadata).interfaceId), true);
        assertEq(metadata.supportsInterface(type(IEnhancedAccessControl).interfaceId), true);
        assertEq(metadata.supportsInterface(type(IERC165).interfaceId), true);
    }
}
