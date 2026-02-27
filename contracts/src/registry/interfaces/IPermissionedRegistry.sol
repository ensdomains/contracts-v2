// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IEnhancedAccessControl} from "../../access-control/interfaces/IEnhancedAccessControl.sol";

import {IStandardRegistry} from "./IStandardRegistry.sol";

/// @dev Interface selector: `0xf2371904`
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
    event TokenResource(uint256 indexed tokenId, uint256 indexed resource);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0xf60759e0`
    error LabelAlreadyReserved(string label);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Prevent label registration until expiry unless caller has `ROLE_RESERVE`.
    /// @param label The label to reserve.
    /// @param expiry When the label can be registered again.
    /// @param resolver The resolver while in reserve.
    function reserve(
        string calldata label,
        address resolver,
        uint64 expiry
    ) external returns (uint256 tokenId);

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
