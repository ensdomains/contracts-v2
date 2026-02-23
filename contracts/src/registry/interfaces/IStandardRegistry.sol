// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/**
 * @title IStandardRegistry
 * @dev Interface for the a standard registry.
 */
interface IStandardRegistry is IRegistry {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /**
     * @dev Error emitted when a name is already registered.
     */
    error NameAlreadyRegistered(string label);

    /**
     * @dev Error emitted when a name has expired.
     */
    error NameExpired(uint256 tokenId);

    /**
     * @dev Error emitted when a name cannot be reduced in expiration.
     */
    error CannotReduceExpiration(uint64 oldExpiration, uint64 newExpiration);

    /**
     * @dev Error emitted when a name cannot be set to a past expiration.
     */
    error CannotSetPastExpiration(uint64 expiry);

    /**
     * @dev Error emitted when a transfer is not allowed due to missing transfer admin role.
     */
    error TransferDisallowed(uint256 tokenId, address from);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /**
     * @dev Registers a new name.
     * @param label The label to register.
     * @param owner The address of the owner of the name.
     * @param registry The registry to set as the name.
     * @param resolver The resolver to set for the name.
     * @param roleBitmap The role bitmap to set for the name.
     * @param expires The expiration date of the name.
     */
    function register(
        string calldata label,
        address owner,
        IRegistry registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expires
    ) external returns (uint256 tokenId);

    /// @notice Renew a subdomain.
    /// @param anyId The labelhash, token ID, or resource.
    /// @param newExpiry The new expiration.
    function renew(uint256 anyId, uint64 newExpiry) external;

    /// @notice Delete a subdomain.
    /// @param anyId The labelhash, token ID, or resource.
    function unregister(uint256 anyId) external;

    /// @notice Change registry of name.
    /// @param anyId The labelhash, token ID, or resource.
    /// @param registry The new registry.
    function setSubregistry(uint256 anyId, IRegistry registry) external;

    /// @notice Change resolver of name.
    /// @param anyId The labelhash, token ID, or resource.
    /// @param resolver The new resolver.
    function setResolver(uint256 anyId, address resolver) external;

    /// @notice Get expiry of name.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The expiry for name.
    function getExpiry(uint256 anyId) external view returns (uint64);
}
