// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC1155Singleton} from "../../erc1155/interfaces/IERC1155Singleton.sol";

interface IRegistry is IERC1155Singleton {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @dev A subdomain was registered.
    event NameRegistered(
        uint256 indexed tokenId,
        bytes32 indexed labelHash,
        string label,
        address owner,
        uint64 expiry,
        address indexed sender
    );

    /// @dev A subdomain was reserved.
    event NameReserved(
        uint256 indexed tokenId,
        bytes32 indexed labelHash,
        string label,
        uint64 expiry,
        address indexed sender
    );

    /// @dev A subdomain was unregistered.
    event NameUnregistered(uint256 indexed tokenId, address indexed sender);

    /// @notice Expiry was changed.
    event ExpiryUpdated(uint256 indexed tokenId, uint64 newExpiry, address indexed sender);

    /// @notice Subregistry was changed.
    event SubregistryUpdated(
        uint256 indexed tokenId,
        IRegistry subregistry,
        address indexed sender
    );

    /// @notice Resolver was changed.
    event ResolverUpdated(uint256 indexed tokenId, address resolver, address indexed sender);

    /// @notice Token was regenerated with a new token ID.
    ///         This occurs when roles are granted or revoked to maintain ERC1155 compliance.
    event TokenRegenerated(uint256 indexed oldTokenId, uint256 indexed newTokenId);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /**
     * @dev Fetches the registry for a subdomain.
     * @param label The label to resolve.
     * @return The address of the registry for this subdomain, or `address(0)` if none exists.
     */
    function getSubregistry(string calldata label) external view returns (IRegistry);

    /**
     * @dev Fetches the resolver responsible for the specified label.
     * @param label The label to fetch a resolver for.
     * @return resolver The address of a resolver responsible for this name, or `address(0)` if none exists.
     */
    function getResolver(string calldata label) external view returns (address);
}
