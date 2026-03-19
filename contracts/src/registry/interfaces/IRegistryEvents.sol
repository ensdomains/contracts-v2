// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/// @notice Events interface for the registry, following ENSIP16.
interface IRegistryEvents {
    /// @notice A label was registered.
    /// @param tokenId The token ID registered.
    /// @param labelHash The label hash registered.
    /// @param label The label registered.
    /// @param owner The owner of the label.
    /// @param expiry The expiry of the label.
    /// @param sender The sender of the call to register.
    event LabelRegistered(
        uint256 indexed tokenId,
        bytes32 indexed labelHash,
        string label,
        address owner,
        uint64 expiry,
        address indexed sender
    );

    /// @notice A label was reserved.
    /// @param tokenId The token ID reserved.
    /// @param labelHash The label hash reserved.
    /// @param label The label reserved.
    /// @param expiry The expiry of the label.
    /// @param sender The sender of the call to reserve.
    event LabelReserved(
        uint256 indexed tokenId, bytes32 indexed labelHash, string label, uint64 expiry, address indexed sender
    );

    /// @notice A label was unregistered.
    /// @param tokenId The token ID unregistered.
    /// @param sender The sender of the call to unregister.
    event LabelUnregistered(uint256 indexed tokenId, address indexed sender);

    /// @notice Expiry of label was changed.
    /// @param tokenId The token ID of the label.
    /// @param newExpiry The new expiry of the label.
    /// @param sender The sender of the call to update the expiry.
    event ExpiryUpdated(uint256 indexed tokenId, uint64 indexed newExpiry, address indexed sender);

    /// @notice Subregistry of label was changed.
    /// @param tokenId The token ID of the label.
    /// @param subregistry The new subregistry.
    /// @param sender The sender of the call to update the subregistry.
    event SubregistryUpdated(uint256 indexed tokenId, IRegistry indexed subregistry, address indexed sender);

    /// @notice Resolver of label was changed.
    /// @param tokenId The token ID of the label.
    /// @param resolver The new resolver.
    /// @param sender The sender of the call to update the resolver.
    event ResolverUpdated(uint256 indexed tokenId, address indexed resolver, address indexed sender);

    /// @notice Token was regenerated with a new token ID.
    ///         This occurs when roles are granted or revoked to maintain ERC1155 compliance.
    /// @param oldTokenId The old token ID.
    /// @param newTokenId The new token ID.
    event TokenRegenerated(uint256 indexed oldTokenId, uint256 indexed newTokenId);

    /// @notice Parent was changed.
    /// @param parent The new parent.
    /// @param label The new label.
    /// @param sender The sender of the call to update the parent.
    event ParentUpdated(IRegistry indexed parent, string label, address indexed sender);
}
