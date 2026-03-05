// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {InvalidOwner, UnauthorizedCaller} from "../CommonErrors.sol";
import {REGISTRATION_ROLE_BITMAP} from "../registrar/ETHRegistrar.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";

import {AbstractWrapperReceiver} from "./AbstractWrapperReceiver.sol";
import {LibMigration} from "./libraries/LibMigration.sol";

/// @title UnlockedMigrationController
/// @notice Handles migration of unlocked .eth 2LD names from ENSv1 to v2. Supports two entry points:
///
/// - Wrapped but unlocked names (ERC1155 from NameWrapper): unwraps via `unwrapETH2LD`
///   then registers. Reverts with `MigrationNotSupported` if the owner-controlled fuse
///   `CANNOT_UNWRAP` has been burned (i.e., the name is Locked and should be migrated via
///   `LockedMigrationController` instead).
/// - Unwrapped names (ERC721 from BaseRegistrar): registers directly.
///
/// Unlike locked migration, no subregistry is deployed and no fuse-to-role translation is
/// performed — the name is registered in the .eth registry with the roles and subregistry
/// specified in the caller-provided `MigrationData`.
contract UnlockedMigrationController is AbstractWrapperReceiver, IERC721Receiver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev A separate burn address for ` tokens to avoid extra logic in `onERC721Received()`.
    address constant _UNWRAP_ADDRESS = address(0xdead);

    /// @dev The ENSv2 .eth `PermissionedRegistry` where migrated names are registered.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _REGISTRAR_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        IPermissionedRegistry ethRegistry,
        INameWrapper nameWrapper
    ) AbstractWrapperReceiver(nameWrapper) {
        ETH_REGISTRY = ethRegistry;
        _REGISTRAR_V1 = nameWrapper.registrar();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IERC721Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @dev Receives an unwrapped .eth name via ERC721 `safeTransferFrom` from the `BaseRegistrar`.
    ///      Decodes a single `LibMigration.Data` from `data` and registers the equivalent name in ENSv2.
    ///
    /// @param tokenId The BaseRegistrar token ID (labelhash) of the name being migrated.
    /// @param data ABI-encoded `LibMigration.Data` struct containing migration parameters.
    function onERC721Received(
        address /*operator*/,
        address /*from*/,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        if (msg.sender != address(_REGISTRAR_V1)) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (data.length < LibMigration.MIN_DATA_SIZE) {
            revert LibMigration.InvalidData();
        }
        LibMigration.Data memory md = abi.decode(data, (LibMigration.Data)); // reverts if invalid
        if (tokenId != uint256(keccak256(bytes(md.label)))) {
            revert LibMigration.NameDataMismatch(tokenId);
        }
        // clear ENSv1 resolver
        _REGISTRAR_V1.reclaim(tokenId, address(this));
        _REGISTRY_V1.setResolver(
            NameCoder.namehash(NameCoder.ETH_NODE, bytes32(tokenId)),
            address(0)
        );
        _inject(md);
        return this.onERC721Received.selector;
    }

    /// @notice Zero registry descendents of migrated tokens.
    function clearRegistryV1(bytes32[] calldata parents, bytes32[] calldata labels) external {
        for (uint256 i; i < parents.length; ++i) {
            _REGISTRY_V1.setSubnodeRecord(parents[i], labels[i], address(this), address(0), 0);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc AbstractWrapperReceiver
    /// @dev Reverts `NameIsLocked` if any token is locked.
    ///      Reverts `NameDataMismatch` if any token is mislabeled.
    ///
    /// @param ids The NameWrapper token IDs (namehash) of the names to migrate.
    /// @param mds The migration parameters for each name, indexed in parallel with `ids`.
    function _migrateWrapped(
        uint256[] calldata ids,
        LibMigration.Data[] calldata mds
    ) internal override {
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            (, uint32 fuses, ) = NAME_WRAPPER.getData(id);
            if (_isLocked(fuses)) {
                revert LibMigration.NameIsLocked(id);
            }
            bytes32 labelHash = keccak256(bytes(mds[i].label));
            if (bytes32(id) != NameCoder.namehash(NameCoder.ETH_NODE, labelHash)) {
                revert LibMigration.NameDataMismatch(id);
            }
            // clear ENSv1 resolver
            NAME_WRAPPER.unwrapETH2LD(labelHash, _UNWRAP_ADDRESS, address(this));
            _REGISTRY_V1.setResolver(bytes32(id), address(0));
            _inject(mds[i]);
        }
    }

    /// @dev Claim premigrated reservation.
    function _inject(LibMigration.Data memory md) internal {
        if (md.owner == address(0)) {
            revert InvalidOwner();
        }
        // Register the name in the ETH registry
        ETH_REGISTRY.register(
            md.label,
            md.owner,
            md.subregistry,
            md.resolver,
            REGISTRATION_ROLE_BITMAP,
            0 // use reserved expiry
        ); // reverts if not RESERVED
    }
}
