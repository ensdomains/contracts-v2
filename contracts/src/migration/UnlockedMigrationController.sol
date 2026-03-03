// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {REGISTRATION_ROLE_BITMAP} from "../registrar/ETHRegistrar.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {WrappedErrorLib} from "../utils/WrappedErrorLib.sol";

import {AbstractWrapperReceiver} from "./AbstractWrapperReceiver.sol";
import {LibMigration} from "./libraries/LibMigration.sol";

/// @title UnlockedMigrationController
/// @dev Contract for the v1-to-v2 migration controller that only handles unlocked .eth 2LD names.
contract UnlockedMigrationController is AbstractWrapperReceiver, IERC721Receiver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    IPermissionedRegistry public immutable ETH_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        IPermissionedRegistry ethRegistry,
        INameWrapper nameWrapper
    ) AbstractWrapperReceiver(nameWrapper) {
        ETH_REGISTRY = ethRegistry;
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

    /// @inheritdoc IERC1155Receiver
    /// @notice Migrate one unlocked NameWrapper token via `safeTransferFrom()`.
    ///         Requires `abi.encode(LibMigration.UnlockedData)` as payload.
    ///         Reverts require `WrappedErrorLib.unwrap()` before processing.
    function onERC1155Received(
        address /*operator*/,
        address /*from*/,
        uint256 id,
        uint256 /*amount*/,
        bytes calldata data
    ) external onlyWrapper withData(data, LibMigration.MIN_UNLOCKED_DATA_SIZE) returns (bytes4) {
        // if (amount != 1) { ... } => never happens :: caught by ERC1155Fuse
        // https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/ERC1155Fuse.sol#L293
        uint256[] memory ids = new uint256[](1);
        LibMigration.UnlockedData[] memory mds = new LibMigration.UnlockedData[](1);
        ids[0] = id;
        mds[0] = abi.decode(data, (LibMigration.UnlockedData)); // reverts if invalid
        try this.finishERC1155Migration(ids, mds) {
            return this.onERC1155Received.selector;
        } catch (bytes memory reason) {
            WrappedErrorLib.wrapAndRevert(reason); // convert all errors to wrapped
        }
    }

    /// @inheritdoc IERC1155Receiver
    /// @notice Migrate multiple NameWrapper tokens via `safeBatchTransferFrom()`.
    ///         Requires `abi.encode(LibMigration.UnlockedData[])` as payload.
    ///         Reverts require `WrappedErrorLib.unwrap()` before processing.
    function onERC1155BatchReceived(
        address /*operator*/,
        address /*from*/,
        uint256[] calldata ids,
        uint256[] calldata /*amounts*/,
        bytes calldata data
    )
        external
        onlyWrapper
        withData(data, 64 + ids.length * LibMigration.MIN_LOCKED_DATA_SIZE)
        returns (bytes4)
    {
        // if (ids.length != amounts.length) { ... } => never happens :: caught by ERC1155Fuse
        // https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/ERC1155Fuse.sol#L162
        // if (amounts[i] != 1) { ... } => never happens :: caught by ERC1155Fuse
        // https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/ERC1155Fuse.sol#L182
        LibMigration.UnlockedData[] memory mds = abi.decode(data, (LibMigration.UnlockedData[])); // reverts if invalid
        try this.finishERC1155Migration(ids, mds) {
            return this.onERC1155BatchReceived.selector;
        } catch (bytes memory reason) {
            WrappedErrorLib.wrapAndRevert(reason); // convert all errors to wrapped
        }
    }

    /// @inheritdoc IERC721Receiver
    /// @notice Migrate ".eth" tokens via `safeTransferFrom()`.
    ///         Requires `abi.encode(LibMigration.UnlockedData[])` as payload.
    function onERC721Received(
        address /*operator*/,
        address /*from*/,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4) {
        if (msg.sender != address(NAME_WRAPPER.registrar())) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (data.length < LibMigration.MIN_UNLOCKED_DATA_SIZE) {
            revert LibMigration.InvalidData();
        }
        LibMigration.UnlockedData memory md = abi.decode(data, (LibMigration.UnlockedData)); // reverts if invalid
        if (tokenId != uint256(keccak256(bytes(md.label)))) {
            revert LibMigration.NameDataMismatch(tokenId);
        }
        _inject(md);
        return this.onERC721Received.selector;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Convert NameWrapper tokens their equivalent ENSv2 form.
    ///      Only callable by ourself and invoked in our `IERC1155Receiver` handlers.
    ///
    /// TODO: gas analysis and optimization
    /// NOTE: converting this to an internal call requires catching many reverts
    function finishERC1155Migration(
        uint256[] calldata ids,
        LibMigration.UnlockedData[] calldata mds
    ) external {
        if (msg.sender != address(this)) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (ids.length != mds.length) {
            revert IERC1155Errors.ERC1155InvalidArrayLength(ids.length, mds.length);
        }
        for (uint256 i; i < ids.length; ++i) {
            uint256 id = ids[i];
            (, uint32 fuses, ) = NAME_WRAPPER.getData(id);
            if (_isLocked(fuses)) {
                revert LibMigration.NameIsLocked(id);
            }
            if (
                bytes32(id) !=
                NameCoder.namehash(NameCoder.ETH_NODE, keccak256(bytes(mds[i].label)))
            ) {
                revert LibMigration.NameDataMismatch(id);
            }
            _inject(mds[i]);
        }
    }

    /// @dev Migrate a name to the registry.
    function _inject(LibMigration.UnlockedData memory md) internal {
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
