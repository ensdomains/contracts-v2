// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {REGISTRATION_ROLE_BITMAP} from "../registrar/ETHRegistrar.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";

import {AbstractWrapperReceiver} from "./AbstractWrapperReceiver.sol";
import {LibMigration} from "./libraries/LibMigration.sol";

/// @title UnlockedMigrationController
/// @dev Contract for the v1-to-v2 migration controller that only handles unlocked .eth 2LD names.
contract UnlockedMigrationController is AbstractWrapperReceiver, IERC721Receiver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    IPermissionedRegistry public immutable ETH_REGISTRY;
    IBaseRegistrar internal immutable _REGISTRAR_V1;
    bool internal _unwrapping;

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

    /// @inheritdoc IERC721Receiver
    /// @notice Migrate ".eth" tokens via `safeTransferFrom()`.
    ///         Requires `abi.encode(LibMigration.Data[])` as payload.
    function onERC721Received(
        address /*operator*/,
        address /*from*/,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        if (msg.sender != address(_REGISTRAR_V1)) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (!_unwrapping) {
            if (data.length < LibMigration.MIN_DATA_SIZE) {
                revert LibMigration.InvalidData();
            }
            LibMigration.Data memory md = abi.decode(data, (LibMigration.Data)); // reverts if invalid
            if (tokenId != uint256(keccak256(bytes(md.label)))) {
                revert LibMigration.NameDataMismatch(tokenId);
            }
            // clear V1 resolver
            _REGISTRAR_V1.reclaim(tokenId, address(this));
            _REGISTRY_V1.setResolver(
                NameCoder.namehash(NameCoder.ETH_NODE, bytes32(tokenId)),
                address(0)
            );
            _inject(md);
        }
        return this.onERC721Received.selector;
    }

    /// @notice Zero registry to any depth for migrated tokens.
    function clearRegistryV1(bytes32[] calldata parents, bytes32[] calldata labels) external {
        for (uint256 i; i < parents.length; ++i) {
            _REGISTRY_V1.setSubnodeRecord(parents[i], labels[i], address(this), address(0), 0);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc AbstractWrapperReceiver
    function _migrate(uint256[] calldata ids, LibMigration.Data[] calldata mds) internal override {
        _unwrapping = true;
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
            // clear V1 resolver
            //NAME_WRAPPER.setResolver(bytes32(id), address(0));
            NAME_WRAPPER.unwrapETH2LD(labelHash, address(this), address(this)); // => onERC721Received()
            _REGISTRY_V1.setResolver(bytes32(id), address(0));
            _inject(mds[i]);
        }
        _unwrapping = false;
    }

    /// @dev Migrate a name to the registry.
    function _inject(LibMigration.Data memory md) internal {
        if (md.owner == address(0)) {
            revert IERC1155Errors.ERC1155InvalidReceiver(md.owner);
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
