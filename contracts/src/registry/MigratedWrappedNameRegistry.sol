// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper, PARENT_CANNOT_CONTROL} from "@ens/contracts/wrapper/INameWrapper.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {LockedNamesLib} from "../migration/libraries/LockedNamesLib.sol";
import {ParentNotMigrated, LabelNotMigrated} from "../migration/MigrationErrors.sol";
import {MigrationData} from "../migration/types/MigrationTypes.sol";

import {IMigratedWrappedNameRegistry} from "./interfaces/IMigratedWrappedNameRegistry.sol";
import {IPermissionedRegistry} from "./interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRegistryMetadata} from "./interfaces/IRegistryMetadata.sol";
import {IStandardRegistry} from "./interfaces/IStandardRegistry.sol";
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

/**
 * @title MigratedWrappedNameRegistry
 * @dev A registry for migrated wrapped names that inherits from PermissionedRegistry and is upgradeable using the UUPS pattern.
 * This contract provides resolver fallback to the universal resolver for names that haven't been migrated yet.
 * It also handles subdomain migration by receiving NFT transfers from the NameWrapper.
 */
contract MigratedWrappedNameRegistry is
    Initializable,
    PermissionedRegistry,
    UUPSUpgradeable,
    IERC1155Receiver,
    IMigratedWrappedNameRegistry
{
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    // TODO: these clobbers ROLE_CAN_TRANSFER_ADMIN and should be in RegistryRolesLib
    uint256 internal constant _ROLE_UPGRADE = 1 << 20;
    uint256 internal constant _ROLE_UPGRADE_ADMIN = _ROLE_UPGRADE << 128;

    INameWrapper public immutable NAME_WRAPPER;

    VerifiableFactory public immutable FACTORY;

    IPermissionedRegistry public immutable ETH_REGISTRY;

    address public immutable FALLBACK_RESOLVER;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    bytes public parentDnsEncodedName;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error NoParentDomain();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        INameWrapper nameWrapper,
        IPermissionedRegistry ethRegistry,
        VerifiableFactory factory,
        IHCAFactoryBasic hcaFactory,
        IRegistryMetadata metadataProvider,
        address fallbackResolver
    ) PermissionedRegistry(hcaFactory, metadataProvider, _msgSender(), 0) {
        NAME_WRAPPER = nameWrapper;
        ETH_REGISTRY = ethRegistry;
        FACTORY = factory;
        FALLBACK_RESOLVER = fallbackResolver;
        // Prevents initialization on the implementation contract
        _disableInitializers();
    }

    /**
     * @dev Initializes the MigratedWrappedNameRegistry contract.
     * @param parentDnsEncodedName_ The DNS-encoded name of the parent domain.
     * @param ownerAddress_ The address that will own this registry.
     * @param ownerRoles_ The roles to grant to the owner.
     * @param registrarAddress_ Optional address to grant ROLE_REGISTRAR permissions (typically for testing).
     */
    function initialize(
        bytes calldata parentDnsEncodedName_,
        address ownerAddress_,
        uint256 ownerRoles_,
        address registrarAddress_
    ) public initializer {
        // TODO: custom error
        require(ownerAddress_ != address(0), "Owner cannot be zero address");

        // Set the parent domain for name resolution fallback
        parentDnsEncodedName = parentDnsEncodedName_;

        // Configure owner with upgrade permissions and specified roles
        _grantRoles(
            ROOT_RESOURCE,
            _ROLE_UPGRADE | _ROLE_UPGRADE_ADMIN | ownerRoles_,
            ownerAddress_,
            false
        );

        // Grant registrar role if specified (typically for testing)
        if (registrarAddress_ != address(0)) {
            _grantRoles(ROOT_RESOURCE, RegistryRolesLib.ROLE_REGISTRAR, registrarAddress_, false);
        }
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(IERC165, PermissionedRegistry) returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function onERC1155Received(
        address /*operator*/,
        address /*from*/,
        uint256 tokenId,
        uint256 /*amount*/,
        bytes calldata data
    ) external virtual returns (bytes4) {
        if (msg.sender != address(NAME_WRAPPER)) {
            revert UnauthorizedCaller(msg.sender);
        }

        (MigrationData memory migrationData) = abi.decode(data, (MigrationData));
        MigrationData[] memory migrationDataArray = new MigrationData[](1);
        migrationDataArray[0] = migrationData;

        uint256[] memory tokenIds = new uint256[](1);
        tokenIds[0] = tokenId;

        _migrateSubdomains(tokenIds, migrationDataArray);

        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address /*operator*/,
        address /*from*/,
        uint256[] calldata tokenIds,
        uint256[] calldata /*amounts*/,
        bytes calldata data
    ) external virtual returns (bytes4) {
        if (msg.sender != address(NAME_WRAPPER)) {
            revert UnauthorizedCaller(msg.sender);
        }

        (MigrationData[] memory migrationDataArray) = abi.decode(data, (MigrationData[]));

        _migrateSubdomains(tokenIds, migrationDataArray);

        return this.onERC1155BatchReceived.selector;
    }

    /// @inheritdoc PermissionedRegistry
    /// @dev Restore the latest resolver to `FALLBACK_RESOLVER` upon visiting migratable children.
    function getResolver(
        string calldata label
    ) public view override(PermissionedRegistry) returns (address) {
        bytes32 node = NameCoder.namehash(
            NameCoder.namehash(parentDnsEncodedName, 0),
            keccak256(bytes(label))
        );
        (address owner, uint32 fuses, ) = NAME_WRAPPER.getData(uint256(node));
        if (owner != address(this) && (fuses & PARENT_CANNOT_CONTROL) != 0) {
            return FALLBACK_RESOLVER;
        }
        return super.getResolver(label);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /**
     * @dev Required override for UUPSUpgradeable - restricts upgrade permissions
     */
    function _authorizeUpgrade(address) internal override onlyRootRoles(_ROLE_UPGRADE) {}

    function _migrateSubdomains(
        uint256[] memory tokenIds,
        MigrationData[] memory migrationDataArray
    ) internal {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (, uint32 fuses, ) = NAME_WRAPPER.getData(tokenIds[i]);

            // Ensure name meets migration requirements
            LockedNamesLib.validateEmancipatedName(fuses, tokenIds[i]);

            // Ensure proper domain hierarchy for migration
            string memory label = _validateHierarchy(
                migrationDataArray[i].transferData.dnsEncodedName,
                0
            );

            // Determine permissions from name configuration (allow subdomain renewal based on fuses)
            (uint256 tokenRoles, uint256 subRegistryRoles) = LockedNamesLib
                .generateRoleBitmapsFromFuses(fuses);

            // Create dedicated registry for the migrated name
            address subregistry = LockedNamesLib.deployMigratedRegistry(
                FACTORY,
                ERC1967Utils.getImplementation(),
                migrationDataArray[i].transferData.owner,
                subRegistryRoles,
                migrationDataArray[i].salt,
                migrationDataArray[i].transferData.dnsEncodedName
            );

            // Complete name registration in new registry
            _register(
                label,
                migrationDataArray[i].transferData.owner,
                IRegistry(subregistry),
                migrationDataArray[i].transferData.resolver,
                tokenRoles,
                migrationDataArray[i].transferData.expires,
                _msgSender()
            );

            // Finalize migration by freezing the name
            LockedNamesLib.freezeName(NAME_WRAPPER, tokenIds[i], fuses);
        }
    }

    function _register(
        string memory label,
        address owner,
        IRegistry registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expires,
        address sender
    ) internal virtual override returns (uint256 tokenId) {
        // Check if the label has an emancipated NFT in the old system
        // For .eth 2LDs, NameWrapper uses keccak256(label) as the token ID
        uint256 legacyTokenId = uint256(keccak256(bytes(label)));
        (, uint32 fuses, ) = NAME_WRAPPER.getData(legacyTokenId);

        // If the name is emancipated (PARENT_CANNOT_CONTROL burned),
        // it must be migrated (owned by this registry)
        if ((fuses & PARENT_CANNOT_CONTROL) != 0) {
            if (NAME_WRAPPER.ownerOf(legacyTokenId) != address(this)) {
                revert LabelNotMigrated(label);
            }
        }

        // Proceed with registration
        return super._register(label, owner, registry, resolver, roleBitmap, expires, sender);
    }

    function _validateHierarchy(
        bytes memory dnsEncodedName,
        uint256 offset
    ) internal view returns (string memory label) {
        // Extract the current label (leftmost, at offset 0)
        uint256 parentOffset;
        (label, parentOffset) = NameCoder.extractLabel(dnsEncodedName, offset);

        // Check if there's no parent (trying to migrate TLD)
        if (dnsEncodedName[parentOffset] == 0) {
            revert NoParentDomain();
        }

        // Extract the parent label
        (string memory parentLabel, uint256 grandparentOffset) = NameCoder.extractLabel(
            dnsEncodedName,
            parentOffset
        );

        // Check if this is a 2LD (parent is "eth" and no grandparent)
        if (
            keccak256(bytes(parentLabel)) == keccak256(bytes("eth")) &&
            dnsEncodedName[grandparentOffset] == 0
        ) {
            // For 2LD: Check that label is NOT registered in ethRegistry
            IRegistry subregistry = ETH_REGISTRY.getSubregistry(label);
            if (address(subregistry) != address(0)) {
                revert IStandardRegistry.NameAlreadyRegistered(label);
            }
        } else {
            // For 3LD+: Check that parent is wrapped and owned by this contract
            bytes32 parentNode = NameCoder.namehash(dnsEncodedName, parentOffset);
            if (
                !NAME_WRAPPER.isWrapped(parentNode) ||
                NAME_WRAPPER.ownerOf(uint256(parentNode)) != address(this)
            ) {
                revert ParentNotMigrated(dnsEncodedName, parentOffset);
            }

            // Also check that the current label is NOT already registered in this registry
            IRegistry subregistry = this.getSubregistry(label);
            if (address(subregistry) != address(0)) {
                revert IStandardRegistry.NameAlreadyRegistered(label);
            }
        }

        return label;
    }
}
