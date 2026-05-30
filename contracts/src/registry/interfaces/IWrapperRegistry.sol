// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IPermissionedRegistry} from "./IPermissionedRegistry.sol";
import {IRegistry} from "./IRegistry.sol";

/// @notice Interface for a registry that manages a locked NameWrapper name.
/// @dev Interface selector: `0x8cdebff4`
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

    /// @notice Call `setResolver()` on the parent registry.
    /// @param resolver The new parent resolver.
    function setParentResolver(address resolver) external;

    /// @notice Call `renew()` on the parent registry.
    /// @param expiry The new parent expiry.
    function renewParent(uint64 expiry) external;

    /// @notice Returns the DNS-encoded name for this registry.
    function getWrappedName() external view returns (bytes memory);

    /// @notice Returns the NameWrapper node (namehash).
    function getWrappedNode() external view returns (bytes32);
}
