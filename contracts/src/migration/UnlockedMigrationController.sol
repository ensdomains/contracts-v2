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

/// @title UnlockedMigrationController
/// @notice Handles migration of unlocked .eth 2LD names from ENS v1 to v2. Supports two entry points:
///
///         - Wrapped but unlocked names (ERC1155 from NameWrapper): unwraps via `unwrapETH2LD`
///           then registers. Reverts with `MigrationNotSupported` if the owner-controlled fuse
///           `CANNOT_UNWRAP` has been burned (i.e., the name is Locked and should be migrated via
///           `LockedMigrationController` instead).
///         - Unwrapped names (ERC721 from BaseRegistrar): registers directly.
///
///         Unlike locked migration, no subregistry is deployed and no fuse-to-role translation is
///         performed — the name is registered in the .eth registry with the roles and subregistry
///         specified in the caller-provided `MigrationData`.
contract UnlockedMigrationController is IERC1155Receiver, IERC721Receiver, ERC165 {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev The ENS v1 `NameWrapper` contract that holds wrapped names as ERC1155 tokens.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev The v2 .eth `PermissionedRegistry` where migrated names are registered.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Thrown when the token ID does not match the label hash derived from the DNS-encoded name
    ///      in the migration data.
    /// @dev Error selector: `0x4fa09b3f`
    error TokenIdMismatch(uint256 tokenId, uint256 expectedTokenId);

    /// @dev Thrown when a wrapped name has the owner-controlled fuse `CANNOT_UNWRAP` burned (i.e.,
    ///      the name is Locked), indicating it should be migrated via `LockedMigrationController`.
    /// @dev Error selector: `0x80da7148`
    error MigrationNotSupported();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(INameWrapper nameWrapper, IPermissionedRegistry ethRegistry) {
        NAME_WRAPPER = nameWrapper;
        ETH_REGISTRY = ethRegistry;
    }

    /// Implements ERC165.supportsInterface
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

    /// @dev Receives a single wrapped name via ERC1155 `safeTransferFrom`. Only callable by the
    ///      `NameWrapper`. Decodes a single `MigrationData` from `data` and delegates to
    ///      `_migrateWrappedEthNames`.
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

        _migrateWrappedEthNames(tokenIds, migrationDataArray);

        return this.onERC1155Received.selector;
    }

    /// @dev Receives a batch of wrapped names via ERC1155 `safeBatchTransferFrom`. Only callable
    ///      by the `NameWrapper`. Decodes a `MigrationData[]` array from `data` and delegates to
    ///      `_migrateWrappedEthNames`.
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

        _migrateWrappedEthNames(tokenIds, migrationDataArray);

        return this.onERC1155BatchReceived.selector;
    }

    /// @dev Receives an unwrapped .eth name via ERC721 `safeTransferFrom` from the `BaseRegistrar`.
    ///      Decodes a single `MigrationData` from `data` and registers the name directly in the
    ///      .eth registry without unwrapping.
    /// @param tokenId The BaseRegistrar token ID (label hash) of the name being migrated.
    /// @param data ABI-encoded `MigrationData` struct containing migration parameters.
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

    /// @dev Iterates over the provided token IDs and checks each name's fuse state. If the
    ///      owner-controlled fuse `CANNOT_UNWRAP` has been burned (name is Locked), reverts with
    ///      `MigrationNotSupported`. Otherwise, unwraps the name via `unwrapETH2LD` and delegates
    ///      to `_migrateNameToRegistry` for registration.
    /// @param tokenIds The NameWrapper token IDs (label hashes) of the names to migrate.
    /// @param migrationDataArray The migration parameters for each name, indexed in parallel with `tokenIds`.
    function _migrateWrappedEthNames(
        uint256[] memory tokenIds,
        MigrationData[] memory migrationDataArray
    ) internal {
        for (uint256 i = 0; i < tokenIds.length; i++) {
            (, uint32 fuses, ) = NAME_WRAPPER.getData(tokenIds[i]);

            if (fuses & CANNOT_UNWRAP != 0) {
                // Name is Locked (CANNOT_UNWRAP burned) — must use LockedMigrationController
                revert MigrationNotSupported();
            } else {
                // Name is not Locked — unwrap before migration
                bytes32 labelHash = bytes32(tokenIds[i]);
                NAME_WRAPPER.unwrapETH2LD(labelHash, address(this), address(this));
                // Process migration
                _migrateNameToRegistry(tokenIds[i], migrationDataArray[i]);
            }
        }
    }

    /// @dev Validates that the token ID matches the label hash from the DNS-encoded name, then
    ///      registers the name in the .eth registry using the owner, subregistry, resolver, roles,
    ///      and expiry from the provided migration data.
    /// @param tokenId The token ID (label hash) of the .eth name being registered.
    /// @param migrationData The migration parameters including transfer data and optional CREATE2 salt.
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
