// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ENS} from "@ens/contracts/registry/ENS.sol";
import {INameWrapper, CANNOT_UNWRAP} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {WrappedErrorLib} from "../utils/WrappedErrorLib.sol";

import {LibMigration} from "./libraries/LibMigration.sol";

/// @title AbstractWrapperReceiver
/// @notice Abstract IERC1155Receiver which handles NameWrapper token migration via transfer.
///
/// NameWrapper only allows `Error(string)` exceptions during transfer and squelches typed errors.
/// https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/ERC1155Fuse.sol#L317-L335
/// This contract, with the aid of WrappedErrorLib, embeds errors that occur during migration into `Error(string)`.
///
/// There are (2) AbstractWrapperReceiver implementations:
/// 1. UnlockedMigrationController accepts unlocked tokens.
/// 2. LockedWrapperReceiver accepts locked tokens.
///
/// `_isLocked()` determines lock status.
///
abstract contract AbstractWrapperReceiver is ERC165, IERC1155Receiver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev The ENSv1 `NameWrapper` contract that holds wrapped names as ERC1155 tokens.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev The ENSv1 `ENSRegistry` contract.
    ENS internal immutable _REGISTRY_V1;

    ////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Restrict `msg.sender` to NameWrapper.
    ///      Reverts wrapped errors for use inside of legacy IERC1155Receiver handler.
    modifier onlyWrapper() {
        if (msg.sender != address(NAME_WRAPPER)) {
            WrappedErrorLib.wrapAndRevert(
                abi.encodeWithSelector(UnauthorizedCaller.selector, msg.sender)
            );
        }
        _;
    }

    /// @dev Avoid `abi.decode()` failure for obviously invalid data.
    ///      Reverts wrapped errors for use inside of legacy IERC1155Receiver handler.
    modifier withData(bytes calldata data, uint256 minimumSize) {
        if (data.length < minimumSize) {
            WrappedErrorLib.wrapAndRevert(
                abi.encodeWithSelector(LibMigration.InvalidData.selector)
            );
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(INameWrapper nameWrapper) {
        NAME_WRAPPER = nameWrapper;
        _REGISTRY_V1 = nameWrapper.ens();
    }

    /// @inheritdoc IERC165
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

    /// @inheritdoc IERC1155Receiver
    /// @notice Migrate one NameWrapper token via `safeTransferFrom()`.
    /// @dev Only callable by NameWrapper.
    ///      Reverts require `WrappedErrorLib.unwrap()` before processing.
    ///
    /// @param id The NameWrapper token ID (namehash) of the name being migrated.
    /// @param data ABI-encoded `LibMigration.Data` struct containing migration parameters.
    function onERC1155Received(
        address /*operator*/,
        address /*from*/,
        uint256 id,
        uint256 /*amount*/,
        bytes calldata data
    ) external onlyWrapper withData(data, LibMigration.MIN_DATA_SIZE) returns (bytes4) {
        // if (amount != 1) { ... } => never happens :: caught by ERC1155Fuse
        // https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/ERC1155Fuse.sol#L293
        uint256[] memory ids = new uint256[](1);
        LibMigration.Data[] memory mds = new LibMigration.Data[](1);
        ids[0] = id;
        mds[0] = abi.decode(data, (LibMigration.Data)); // reverts if invalid
        try this.finishERC1155Migration(ids, mds) {
            return this.onERC1155Received.selector;
        } catch (bytes memory reason) {
            WrappedErrorLib.wrapAndRevert(reason); // convert all errors to wrapped
        }
    }

    /// @inheritdoc IERC1155Receiver
    /// @notice Migrate multiple NameWrapper tokens via `safeBatchTransferFrom()`.
    /// @dev Only callable by NameWrapper.
    ///      Reverts require `WrappedErrorLib.unwrap()` before processing.
    ///
    /// @param ids The NameWrapper token IDs (namehashes) of the names being migrated.
    /// @param data ABI-encoded `LibMigration.Data[]` array containing migration parameters for each name.
    function onERC1155BatchReceived(
        address /*operator*/,
        address /*from*/,
        uint256[] calldata ids,
        uint256[] calldata /*amounts*/,
        bytes calldata data
    )
        external
        onlyWrapper
        withData(data, 64 + ids.length * LibMigration.MIN_DATA_SIZE)
        returns (bytes4)
    {
        // if (ids.length != amounts.length) { ... } => never happens :: caught by ERC1155Fuse
        // https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/ERC1155Fuse.sol#L162
        // if (amounts[i] != 1) { ... } => never happens :: caught by ERC1155Fuse
        // https://github.com/ensdomains/ens-contracts/blob/staging/contracts/wrapper/ERC1155Fuse.sol#L182
        LibMigration.Data[] memory mds = abi.decode(data, (LibMigration.Data[])); // reverts if invalid
        try this.finishERC1155Migration(ids, mds) {
            return this.onERC1155BatchReceived.selector;
        } catch (bytes memory reason) {
            WrappedErrorLib.wrapAndRevert(reason); // convert all errors to wrapped
        }
    }

    /// @dev Convert NameWrapper tokens to their equivalent ENSv2 form.
    ///      Only callable by ourself and invoked by our `IERC1155Receiver` handlers.
    ///
    /// TODO: gas analysis and optimization
    /// NOTE: converting this to an internal call requires catching many reverts
    function finishERC1155Migration(
        uint256[] calldata ids,
        LibMigration.Data[] calldata mds
    ) external {
        if (msg.sender != address(this)) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (ids.length != mds.length) {
            revert IERC1155Errors.ERC1155InvalidArrayLength(ids.length, mds.length);
        }
        _migrateWrapped(ids, mds);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Abstract function to migrate received NameWrapper tokens.
    ///      Token owner is this contract.
    ///      Token is not expired.
    function _migrateWrapped(
        uint256[] calldata ids,
        LibMigration.Data[] calldata mds
    ) internal virtual;

    /// @dev Returns `true` if the NameWrapper token is locked.
    function _isLocked(uint32 fuses) internal pure returns (bool) {
        // PARENT_CANNOT_CONTROL is required to set CANNOT_UNWRAP, so CANNOT_UNWRAP is sufficient
        // see: V1Fixture.t.sol: `test_nameWrapper_CANNOT_UNWRAP_requires_PARENT_CANNOT_CONTROL()`
        return (fuses & CANNOT_UNWRAP) != 0;
    }
}
