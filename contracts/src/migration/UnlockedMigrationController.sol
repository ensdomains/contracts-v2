// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper, CANNOT_UNWRAP} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";

import {MigrationData} from "./types/MigrationTypes.sol";

/**
 * @title UnlockedMigrationController
 * @dev Contract for the v1-to-v2 migration controller that only handles unlocked .eth 2LD names.
 */
contract UnlockedMigrationController is IERC1155Receiver, IERC721Receiver, ERC165 {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    INameWrapper public immutable NAME_WRAPPER;

    IPermissionedRegistry public immutable ETH_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0x4fa09b3f`
    error TokenIdMismatch(uint256 tokenId, uint256 expectedTokenId);

    /// @dev Error selector: `0x80da7148`
    error MigrationNotSupported();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(INameWrapper nameWrapper, IPermissionedRegistry ethRegistry) {
        NAME_WRAPPER = nameWrapper;
        ETH_REGISTRY = ethRegistry;
    }

    /**
     * Implements ERC165.supportsInterface
     */
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IERC721Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /**
     * Implements ERC1155Receiver.onERC1155Received
     */
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

        _migrateWrappedEthNames(tokenIds, migrationDataArray);

        return this.onERC1155Received.selector;
    }

    /**
     * Implements ERC1155Receiver.onERC1155BatchReceived
     */
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

        _migrateWrappedEthNames(tokenIds, migrationDataArray);

        return this.onERC1155BatchReceived.selector;
    }

    /**
     * @dev Implements ERC721Receiver.onERC721Received
     *
     * If this is called then it means an unwrapped .eth name is being migrated to v2.
     */
    function onERC721Received(
        address /*operator*/,
        address /*from*/,
        uint256 tokenId,
        bytes calldata data
    ) external virtual returns (bytes4) {
        if (msg.sender != address(NAME_WRAPPER.registrar())) {
            revert UnauthorizedCaller(msg.sender);
        }

        (MigrationData memory migrationData) = abi.decode(data, (MigrationData));

        _migrateNameToRegistry(tokenId, migrationData);

        return this.onERC721Received.selector;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /**
     * @dev Called when wrapped .eth 2LD names are being migrated to v2.
     * Only supports unlocked names - reverts for locked names.
     *
     * @param tokenIds The token IDs of the .eth names.
     * @param migrationDataArray The migration data for each .eth name.
     */
    function _migrateWrappedEthNames(
        uint256[] memory tokenIds,
        MigrationData[] memory migrationDataArray
    ) internal {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (, uint32 fuses, ) = NAME_WRAPPER.getData(tokenIds[i]);

            if (fuses & CANNOT_UNWRAP != 0) {
                // Name is locked
                revert MigrationNotSupported();
            } else {
                // Unwrap the unlocked name before migration
                bytes32 labelHash = bytes32(tokenIds[i]);
                NAME_WRAPPER.unwrapETH2LD(labelHash, address(this), address(this));
                // Process migration
                _migrateNameToRegistry(tokenIds[i], migrationDataArray[i]);
            }
        }
    }

    /**
     * @dev Migrate a name to the registry.
     *
     * @param tokenId The token ID of the .eth name.
     * @param migrationData The migration data.
     */
    function _migrateNameToRegistry(uint256 tokenId, MigrationData memory migrationData) internal {
        // Validate that tokenId matches the label hash
        (bytes32 labelHash, ) = NameCoder.readLabel(migrationData.transferData.dnsEncodedName, 0);
        if (tokenId != uint256(labelHash)) {
            revert TokenIdMismatch(tokenId, uint256(labelHash));
        }

        // Register the name in the ETH registry
        string memory label = NameCoder.firstLabel(migrationData.transferData.dnsEncodedName);
        ETH_REGISTRY.register(
            label,
            migrationData.transferData.owner,
            IRegistry(migrationData.transferData.subregistry),
            migrationData.transferData.resolver,
            migrationData.transferData.roleBitmap,
            migrationData.transferData.expires
        );
    }
}
