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

contract LockedMigrationController is IERC1155Receiver, ERC165 {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    INameWrapper public immutable NAME_WRAPPER;

    IPermissionedRegistry public immutable ETH_REGISTRY;

    VerifiableFactory public immutable FACTORY;

    address public immutable MIGRATED_REGISTRY_IMPLEMENTATION;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

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

    function _migrateLockedEthNames(
        uint256[] memory tokenIds,
        MigrationData[] memory migrationDataArray
    ) internal {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (, uint32 fuses, ) = NAME_WRAPPER.getData(tokenIds[i]);

            // Validate fuses and name type
            LockedNamesLib.validateLockedName(fuses, tokenIds[i]);
            LockedNamesLib.validateIsDotEth2LD(fuses, tokenIds[i]);

            // Determine permissions from name configuration (mask out CAN_EXTEND_EXPIRY to prevent automatic renewal for 2LDs)
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
