// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IEnhancedAccessControl} from "../../access-control/interfaces/IEnhancedAccessControl.sol";

import {IStandardRegistry, IRegistry} from "./IStandardRegistry.sol";

interface IPermissionedRegistry is IStandardRegistry, IEnhancedAccessControl {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    enum NameState {
        AVAILABLE,
        RESERVED,
        REGISTERED
    }

    struct Entry {
        uint32 eacVersionId;
        uint32 tokenVersionId;
        IRegistry subregistry;
        uint64 expiry;
        address resolver;
    }

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Associate a token with an EAC resource.
    event TokenResource(uint256 indexed tokenId, uint256 indexed resource);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error NameIsReserved();

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Prevent subdomain registration until expiry unless caller has `ROLE_RESERVE`.
    /// @param label The subdomain to reserve.
    /// @param expiry The time when the subdomain can be registered again.
    /// @param resolver The resolver while in reserve.
    function reserve(string calldata label, address resolver, uint64 expiry) external;

    /// @notice Get the latest owner of a token.
    ///         If the token was burned, returns null.
    /// @param tokenId The token ID to query.
    /// @return The latest owner address.
    function latestOwnerOf(uint256 tokenId) external view returns (address);

    /// @notice Determine subdomain registration state.
    /// @param label The subdomain to check.
    /// @return The registration state.
    function getNameState(string calldata label) external view returns (NameState);

    /**
     * @dev Fetches the name data for a label.
     * @param label The label to fetch the name data for.
     * @return tokenId The token ID of the name.
     * @return entry The entry data for the name.
     */
    function getNameData(
        string calldata label
    ) external view returns (uint256 tokenId, Entry memory entry);

    /// @notice Get datastore `Entry` from `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The datastore entry.
    function getEntry(uint256 anyId) external view returns (Entry memory);

    /// @notice Get `resource` from `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The resource.
    function getResource(uint256 anyId) external view returns (uint256);

    /// @notice Get `tokenId` from `anyId`.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The token ID.
    function getTokenId(uint256 anyId) external view returns (uint256);
}
