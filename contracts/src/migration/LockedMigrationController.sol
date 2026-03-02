// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper, CAN_EXTEND_EXPIRY} from "@ens/contracts/wrapper/INameWrapper.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";

import {LockedNamesLib} from "./libraries/LockedNamesLib.sol";
import {MigrationData} from "./types/MigrationTypes.sol";

/// @notice Handles migration of Locked .eth 2LD names from the ENS v1 NameWrapper to the v2
///         registry system. A name is Locked when the owner-controlled fuse `CANNOT_UNWRAP` has
///         been burned. Additionally validates that the `IS_DOT_ETH` fuse is present, confirming
///         the name is a .eth 2LD. Receives NFTs via ERC1155
///         transfer from the NameWrapper.
///
///         Migration flow per name: validate the name is Locked and is a .eth 2LD → translate
///         the NameWrapper fuse configuration into v2 role bitmaps → deploy a
///         `MigratedWrappedNameRegistry` subregistry via `VerifiableFactory` (CREATE2) → register
///         the name in the .eth registry with the translated roles → freeze the name in the
///         NameWrapper by burning all remaining owner-controlled fuses.
///
///         The parent-controlled fuse `CAN_EXTEND_EXPIRY` is masked out for 2LDs to prevent
///         automatic renewal in the new system.
contract LockedMigrationController is IERC1155Receiver, ERC165 {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev The ENS v1 `NameWrapper` contract that holds wrapped names as ERC1155 tokens.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev The v2 .eth `PermissionedRegistry` where migrated names are registered.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    /// @dev The `VerifiableFactory` used for deterministic (CREATE2) deployment of subregistries.
    VerifiableFactory public immutable FACTORY;

    /// @dev The implementation contract used as the template for `MigratedWrappedNameRegistry` proxies.
    address public immutable MIGRATED_REGISTRY_IMPLEMENTATION;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Thrown when the ERC1155 `tokenId` does not match the label hash derived from the
    ///      DNS-encoded name in the migration data.
    /// @dev Error selector: `0x4fa09b3f`
    error TokenIdMismatch(uint256 tokenId, uint256 expectedTokenId);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        INameWrapper nameWrapper,
        IPermissionedRegistry ethRegistry,
        VerifiableFactory factory,
        address migratedRegistryImplementation
    ) {
        NAME_WRAPPER = nameWrapper;
        ETH_REGISTRY = ethRegistry;
        FACTORY = factory;
        MIGRATED_REGISTRY_IMPLEMENTATION = migratedRegistryImplementation;
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @dev Receives a single wrapped name via ERC1155 `safeTransferFrom`. Only callable by the
    ///      `NameWrapper`. Decodes a single `MigrationData` from `data` and delegates to
    ///      `_migrateLockedEthNames`.
    /// @param tokenId The NameWrapper token ID (label hash) of the name being migrated.
    /// @param data ABI-encoded `MigrationData` struct containing migration parameters.
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

        _migrateLockedEthNames(tokenIds, migrationDataArray);

        return this.onERC1155Received.selector;
    }

    /// @dev Receives a batch of wrapped names via ERC1155 `safeBatchTransferFrom`. Only callable
    ///      by the `NameWrapper`. Decodes a `MigrationData[]` array from `data` and delegates to
    ///      `_migrateLockedEthNames`.
    /// @param tokenIds The NameWrapper token IDs (label hashes) of the names being migrated.
    /// @param data ABI-encoded `MigrationData[]` array containing migration parameters for each name.
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

        _migrateLockedEthNames(tokenIds, migrationDataArray);

        return this.onERC1155BatchReceived.selector;
    }

    /// @dev Iterates over the provided token IDs, validates each name is locked and a .eth 2LD,
    ///      translates NameWrapper fuses into v2 role bitmaps, deploys a `MigratedWrappedNameRegistry`
    ///      subregistry via CREATE2, registers the name in the .eth registry, and freezes the name
    ///      in the NameWrapper.
    /// @param tokenIds The NameWrapper token IDs (label hashes) of the names to migrate.
    /// @param migrationDataArray The migration parameters for each name, indexed in parallel with `tokenIds`.
    function _migrateLockedEthNames(
        uint256[] memory tokenIds,
        MigrationData[] memory migrationDataArray
    ) internal {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (, uint32 fuses, ) = NAME_WRAPPER.getData(tokenIds[i]);

            // Validate fuses and name type
            LockedNamesLib.validateLockedName(fuses, tokenIds[i]);
            LockedNamesLib.validateIsDotEth2LD(fuses, tokenIds[i]);

            // Mask out the parent-controlled fuse CAN_EXTEND_EXPIRY to prevent automatic renewal for 2LDs
            uint32 adjustedFuses = fuses & ~CAN_EXTEND_EXPIRY;
            (uint256 tokenRoles, uint256 subRegistryRoles) = LockedNamesLib
                .generateRoleBitmapsFromFuses(adjustedFuses);

            // Create new registry instance for the migrated name
            address subregistry = LockedNamesLib.deployMigratedRegistry(
                FACTORY,
                MIGRATED_REGISTRY_IMPLEMENTATION,
                migrationDataArray[i].transferData.owner,
                subRegistryRoles,
                migrationDataArray[i].salt,
                migrationDataArray[i].transferData.dnsEncodedName
            );

            // Configure transfer data with registry and permission details
            migrationDataArray[i].transferData.subregistry = subregistry;
            migrationDataArray[i].transferData.roleBitmap = tokenRoles;

            // Ensure name data consistency for migration
            (bytes32 labelHash, ) = NameCoder.readLabel(
                migrationDataArray[i].transferData.dnsEncodedName,
                0
            );
            if (tokenIds[i] != uint256(labelHash)) {
                revert TokenIdMismatch(tokenIds[i], uint256(labelHash));
            }

            // Register the name in the ETH registry
            string memory label = NameCoder.firstLabel(
                migrationDataArray[i].transferData.dnsEncodedName
            );
            ETH_REGISTRY.register(
                label,
                migrationDataArray[i].transferData.owner,
                IRegistry(migrationDataArray[i].transferData.subregistry),
                migrationDataArray[i].transferData.resolver,
                migrationDataArray[i].transferData.roleBitmap,
                migrationDataArray[i].transferData.expires
            );

            // Finalize migration by freezing the name
            LockedNamesLib.freezeName(NAME_WRAPPER, tokenIds[i], fuses);
        }
    }
}
