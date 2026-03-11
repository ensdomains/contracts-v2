// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/// @notice Events interface for the registry, following ENSIP16.
interface IRegistryEvents {
    /// @notice A label was registered.
    event LabelRegistered(
        uint256 indexed tokenId,
        bytes32 indexed labelHash,
        string label,
        address owner,
        uint64 expiry,
        address indexed sender
    );

    /// @notice A label was reserved.
    event LabelReserved(
        uint256 indexed tokenId,
        bytes32 indexed labelHash,
        string label,
        uint64 expiry,
        address indexed sender
    );

    /// @notice A label was unregistered.
    event LabelUnregistered(uint256 indexed tokenId, address indexed sender);

    /// @notice Expiry of label was changed.
    event ExpiryUpdated(uint256 indexed tokenId, uint64 indexed newExpiry, address indexed sender);

    /// @notice Subregistry of label was changed.
    event SubregistryUpdated(
        uint256 indexed tokenId,
        IRegistry indexed subregistry,
        address indexed sender
    );

    /// @notice Resolver of label was changed.
    event ResolverUpdated(
        uint256 indexed tokenId,
        address indexed resolver,
        address indexed sender
    );

    /// @notice Token was regenerated with a new token ID.
    ///         This occurs when roles are granted or revoked to maintain ERC1155 compliance.
    event TokenRegenerated(uint256 indexed oldTokenId, uint256 indexed newTokenId);

    /// @notice Parent was changed.
    event ParentUpdated(IRegistry indexed parent, string label, address indexed sender);
}
