// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IPermissionedRegistry} from "./IPermissionedRegistry.sol";
import {IRegistry} from "./IRegistry.sol";

/// @notice Interface for a registry that manages a locked NameWrapper name.
/// @dev Interface selector: `0x6b2f7339`
interface IWrapperRegistry is IPermissionedRegistry {
    /// @param node Namehash of this registry.
    /// @param parentRegistry The parent of this registry.
    /// @param childLabel The subdomain for this registry.
    /// @param admin Address that will control this registry.
    /// @param roleBitmap The roles assigned to `admin`.
    function initialize(
        bytes32 node,
        IRegistry parentRegistry,
        string calldata childLabel,
        address admin,
        uint256 roleBitmap
    ) external;

    /// @notice The DNS-encoded name for this registry.
    function getWrappedName() external view returns (bytes memory);

    /// @notice The NameWrapper node (namehash).
    function getWrappedNode() external view returns (bytes32);
}
