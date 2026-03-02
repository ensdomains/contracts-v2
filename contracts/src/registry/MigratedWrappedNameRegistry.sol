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

/// @title MigratedWrappedNameRegistry
/// @notice UUPS-upgradeable `PermissionedRegistry` for names migrated from the ENS v1 `NameWrapper`.
///         Deployed as a per-name subregistry during locked name migration.
///
///         Implements `IERC1155Receiver` to accept subdomain NFTs transferred from the NameWrapper
///         for migration. On receipt, it validates the subdomain is Emancipated (i.e., the
///         parent-controlled fuse `PARENT_CANNOT_CONTROL` has been burned), verifies the domain
///         hierarchy, deploys a child `MigratedWrappedNameRegistry` via `VerifiableFactory`,
///         registers the subdomain, and freezes the name in the NameWrapper.
///
///         Overrides `getResolver`: for Emancipated subdomains still in the NameWrapper (not yet
///         migrated), returns the fallback resolver so resolution can proceed without requiring
///         migration first.
///
///         Overrides `register`: for Emancipated subdomains (those with `PARENT_CANNOT_CONTROL`
///         burned), requires the subdomain NFT to have been transferred to this registry before
///         registration, preventing registration of names that haven't completed migration.
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

    /// @dev Reference to the ENS v1 `NameWrapper` contract from which subdomain NFTs are transferred.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev `VerifiableFactory` used to deploy child `MigratedWrappedNameRegistry` proxies for subdomains.
    VerifiableFactory public immutable FACTORY;

    /// @dev The `.eth` registry used to verify second-level domain registration status during migration.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    /// @dev Resolver returned for emancipated subdomains that have not yet been migrated, allowing
    ///      name resolution to continue without requiring migration first.
    address public immutable FALLBACK_RESOLVER;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev DNS wire-format encoded name of the parent domain, set during initialization.
    bytes public parentDnsEncodedName;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0xd1697407`
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

    /// @notice Initializes a proxy instance of `MigratedWrappedNameRegistry`.
    /// @dev Stores the parent DNS name, grants upgrade and owner roles to `ownerAddress_`, and
    ///      optionally grants the registrar role to `registrarAddress_`.
    /// @param parentDnsEncodedName_ DNS wire-format encoded name of the parent domain.
    /// @param ownerAddress_ Address that will own this subregistry.
    /// @param ownerRoles_ Role bitmap to grant to the owner (combined with upgrade roles).
    /// @param registrarAddress_ Address to grant the registrar role to; pass the zero address to skip.
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
            RegistryRolesLib.ROLE_UPGRADE | RegistryRolesLib.ROLE_UPGRADE_ADMIN | ownerRoles_,
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

    /// @notice Handles a single ERC-1155 token transfer from the `NameWrapper`.
    /// @dev Decodes the migration data from `data`, delegates to `_migrateSubdomains`, and returns
    ///      the ERC-1155 receiver selector. Reverts if the caller is not the `NameWrapper`.
    /// @param tokenId The `NameWrapper` node ID of the transferred subdomain NFT.
    /// @param data ABI-encoded `MigrationData` struct for the subdomain.
    /// @return The `onERC1155Received` function selector.
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

    /// @notice Handles a batch ERC-1155 token transfer from the `NameWrapper`.
    /// @dev Decodes an array of `MigrationData` from `data`, delegates to `_migrateSubdomains`,
    ///      and returns the ERC-1155 batch receiver selector. Reverts if the caller is not the `NameWrapper`.
    /// @param tokenIds The `NameWrapper` node IDs of the transferred subdomain NFTs.
    /// @param data ABI-encoded `MigrationData[]` array, one entry per token.
    /// @return The `onERC1155BatchReceived` function selector.
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
    /// @dev Blocks registration of unmigrated Emancipated children. If the label has
    ///      `PARENT_CANNOT_CONTROL` burned in the NameWrapper, the NFT must have been transferred
    ///      to this registry (i.e., migrated) before registration is allowed.
    function register(
        string memory label,
        address owner,
        IRegistry registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expires
    ) public virtual override returns (uint256 tokenId) {
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
        return super.register(label, owner, registry, resolver, roleBitmap, expires);
    }

    /// @inheritdoc PermissionedRegistry
    /// @dev Returns the fallback resolver for Emancipated subdomains (those with `PARENT_CANNOT_CONTROL`
    ///      burned) that are still held by the NameWrapper and not yet migrated. This allows name
    ///      resolution to continue without requiring migration first.
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

    /// @dev Restricts UUPS upgrades to accounts holding the upgrade role on the root resource.
    function _authorizeUpgrade(
        address
    ) internal override onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE) {}

    /// @dev Migrates one or more subdomains from the `NameWrapper` into this registry.
    ///      For each token: validates the name is Emancipated (`PARENT_CANNOT_CONTROL` burned),
    ///      verifies the domain hierarchy, deploys a child `MigratedWrappedNameRegistry` proxy,
    ///      registers the subdomain, and freezes the legacy name.
    /// @param tokenIds Array of `NameWrapper` node IDs for the subdomains being migrated.
    /// @param migrationDataArray Corresponding array of `MigrationData` structs carrying owner,
    ///        resolver, expiry, DNS-encoded name, and factory salt for each subdomain.
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
            super.register(
                label,
                migrationDataArray[i].transferData.owner,
                IRegistry(subregistry),
                migrationDataArray[i].transferData.resolver,
                tokenRoles,
                migrationDataArray[i].transferData.expires
            );

            // Finalize migration by freezing the name
            LockedNamesLib.freezeName(NAME_WRAPPER, tokenIds[i], fuses);
        }
    }

    /// @dev Validates that the DNS-encoded name belongs under the expected parent before migration.
    ///      For second-level domains, checks the `.eth` registry to ensure the label is not already
    ///      registered. For deeper subdomains, verifies that the parent is still wrapped and owned
    ///      by this contract, and that the label has not already been registered here.
    /// @param dnsEncodedName Full DNS wire-format encoded name of the subdomain being migrated.
    /// @param offset Byte offset into `dnsEncodedName` at which to begin label extraction.
    /// @return label The extracted leftmost label from `dnsEncodedName`.
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
