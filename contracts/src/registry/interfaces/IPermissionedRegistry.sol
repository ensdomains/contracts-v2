// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IEnhancedAccessControl} from "../../access-control/interfaces/IEnhancedAccessControl.sol";

import {IStandardRegistry} from "./IStandardRegistry.sol";

/// @dev Interface selector: `0x937fca22`
interface IPermissionedRegistry is IStandardRegistry, IEnhancedAccessControl {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice The registration status of a label.
    enum Status {
        AVAILABLE,
        RESERVED,
        REGISTERED
    }

    /// @notice The registration state of a label.
    struct State {
        Status status; // getStatus()
        uint64 expiry; // getExpiry()
        address latestOwner; // latestOwnerOf()
        uint256 tokenId; // getTokenId()
        uint256 resource; // getResource()
    }

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Associate a token with an EAC resource.
    /// @param tokenId The token ID.
    /// @param resource The EAC resource.
    event TokenResource(uint256 indexed tokenId, uint256 indexed resource);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Label cannot be reserved again.
    /// @dev Error selector: `0xf60759e0`
    error LabelAlreadyReserved(string label);

    /// @notice Transfer is blocked by a name-level transfer lock.
    /// @dev Error selector: `0xa9de8c6f`
    error TransferLocked(uint256 tokenId);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Atomically locks transfers on a name and revokes the specified roles from an account.
    ///
    /// The lock prevents any ERC1155 token transfers for the name regardless of per-account
    /// `ROLE_CAN_TRANSFER_ADMIN` grants, closing the front-running window where a user could
    /// transfer the token to evade a pending role revocation.
    ///
    /// @param anyId The labelhash, token ID, or resource.
    /// @param roleBitmap The roles bitmap to revoke from `account`.
    /// @param account The account to revoke roles from.
    function revokeRolesAndLockTransfer(
        uint256 anyId,
        uint256 roleBitmap,
        address account
    ) external;

    /// @notice Sets or clears the transfer lock on a name.
    ///
    /// When locked, all ERC1155 token transfers for this name are blocked regardless of
    /// per-account roles. Only callable by accounts holding `ROLE_CAN_TRANSFER_ADMIN`
    /// on the `ROOT_RESOURCE`.
    ///
    /// @param anyId The labelhash, token ID, or resource.
    /// @param locked Whether to lock (`true`) or unlock (`false`) transfers.
    function setTransferLock(uint256 anyId, bool locked) external;

    /// @notice Returns whether transfers are locked for the given name.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return `true` if transfers are locked, `false` otherwise.
    function isTransferLocked(uint256 anyId) external view returns (bool);

    /// @notice Get the latest owner of a token.
    ///         If the token was burned, returns null.
    /// @param tokenId The token ID to query.
    /// @return owner The latest owner address.
    function latestOwnerOf(uint256 tokenId) external view returns (address owner);

    /// @notice Get the state of a label.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return state The state of the label.
    function getState(uint256 anyId) external view returns (State memory state);

    /// @notice Get `Status` from `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return status The status of the label.
    function getStatus(uint256 anyId) external view returns (Status status);

    /// @notice Get `resource` from `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return resource The resource.
    function getResource(uint256 anyId) external view returns (uint256 resource);

    /// @notice Get `tokenId` from `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return tokenId The token ID.
    function getTokenId(uint256 anyId) external view returns (uint256 tokenId);
}
