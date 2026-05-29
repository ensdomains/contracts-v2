// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IPermissionedRegistry} from "./IPermissionedRegistry.sol";
import {IRegistry} from "./IRegistry.sol";

/// @notice Interface for a registry that manages a locked NameWrapper name.
/// @dev Interface selector: `0x4b8898e7`
interface IWrapperRegistry is IPermissionedRegistry {
    /// @notice Initializes WrapperRegistry.
    /// @param node Namehash of this registry.
    /// @param parentRegistry The parent of this registry.
    /// @param childLabel The subdomain for this registry.
    /// @param rootAccount Account granted root roles.
    /// @param roleBitmap The role bitmap granted to `rootAccount`.
    function initialize(
        bytes32 node,
        IRegistry parentRegistry,
        string calldata childLabel,
        address rootAccount,
        uint256 roleBitmap
    )
        external;

    /// @notice Move the seller's root-resource role grants to the buyer when the parent
    ///         registry transfers the NFT corresponding to this wrapped name.
    /// @dev Only the parent registry may call this, and only for the token whose label
    ///      matches this registry's child label.
    /// @param parentTokenId The parent registry token ID being transferred.
    /// @param from The seller of the parent NFT.
    /// @param to The buyer of the parent NFT.
    function transferRootRoles(uint256 parentTokenId, address from, address to) external;

    /// @notice Returns the DNS-encoded name for this registry.
    function getWrappedName() external view returns (bytes memory);

    /// @notice Returns the NameWrapper node (namehash).
    function getWrappedNode() external view returns (bytes32);
}
