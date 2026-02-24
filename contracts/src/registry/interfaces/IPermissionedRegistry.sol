// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IEnhancedAccessControl} from "../../access-control/interfaces/IEnhancedAccessControl.sol";

import {IStandardRegistry} from "./IStandardRegistry.sol";

/// @dev Interface selector: `0xf2371904`
interface IPermissionedRegistry is IStandardRegistry, IEnhancedAccessControl {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice The registration status of a subdomain.
    enum Status {
        AVAILABLE,
        RESERVED,
        REGISTERED
    }

    /// @notice The registration state of a subdomain.
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

    /// @dev Error selector: `0xee7f75f7`
    error NameAlreadyReserved(string label);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Prevent subdomain registration until expiry unless caller has `ROLE_RESERVE`.
    /// @param label The subdomain to reserve.
    /// @param expiry The time when the subdomain can be registered again.
    /// @param resolver The resolver while in reserve.
    function reserve(
        string calldata label,
        address resolver,
        uint64 expiry
    ) external returns (uint256 tokenId);

    /// @notice Get the latest owner of a token.
    ///         If the token was burned, returns null.
    /// @param tokenId The token ID to query.
    /// @return The latest owner address.
    function latestOwnerOf(uint256 tokenId) external view returns (address);

    /// @notice Get the state of a subdomain.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The state of the subdomain.
    function getState(uint256 anyId) external view returns (State memory);

    /// @notice Get `Status` from `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The status of the subdomain.
    function getStatus(uint256 anyId) external view returns (Status);

    /// @notice Get `resource` from `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The resource.
    function getResource(uint256 anyId) external view returns (uint256);

    /// @notice Get `tokenId` from `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The token ID.
    function getTokenId(uint256 anyId) external view returns (uint256);
}
