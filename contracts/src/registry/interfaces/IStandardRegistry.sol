// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/// @title IStandardRegistry
/// @notice A tokenized registry.
/// @dev Interface selector: `0xb844ab6c`
interface IStandardRegistry is IRegistry {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Name is already registered.
    /// @dev Error selector: `0x6dbb87d0`
    error NameAlreadyRegistered(string label);

    /// @notice Name is expired/unregistered.
    /// @dev Error selector: `0x0c23d840`
    error NameExpired(uint256 tokenId);

    /// @notice Name expiry cannot be reduced.
    /// @dev Error selector: `0x9967595a`
    error CannotReduceExpiration(uint64 oldExpiration, uint64 newExpiration);

    /// @notice Name expory cannot be before now.
    /// @dev Error selector: `0x6a0147dc`
    error CannotSetPastExpiration(uint64 expiry);

    /// @notice Transfer is not allowed due to missing transfer admin role.
    /// @dev Error selector: `0xe58f6d5a`
    error TransferDisallowed(uint256 tokenId, address from);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Registers a new name.
    /// @param label The label to register.
    /// @param owner The address of the owner of the name.
    /// @param registry The registry to set as the name.
    /// @param resolver The resolver to set for the name.
    /// @param roleBitmap The role bitmap to set for the name.
    /// @param expires The expiration date of the name.
    /// @return tokenId The token ID.
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

    /// @notice Change canonical "location".
    /// @dev Should emit `ParentUpdated`.
    /// @param parent The canonical parent of this registry.
    /// @param label The canonical subdomain of this registry.
    function setParent(IRegistry parent, string calldata label) external;

    /// @notice Get expiry of name.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return The expiry for name.
    function getExpiry(uint256 anyId) external view returns (uint64);
}
