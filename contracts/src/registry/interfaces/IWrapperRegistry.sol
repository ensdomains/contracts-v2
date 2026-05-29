// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IPermissionedRegistry} from "./IPermissionedRegistry.sol";
import {IRegistry} from "./IRegistry.sol";

/// @notice Interface for a registry that manages a locked NameWrapper name.
/// @dev Interface selector: `0xf9fc8b9c`
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

    /// @notice Reclaim the registry from a prior owner.
    /// @dev Requires `ROLE_WRAPPER_RECLAIM` on token.
    /// @param to The new root account.
    /// @param revokes The old root accounts which get fully revoked.
    function reclaim(address to, address[] calldata revokes) external;

    /// @notice Returns the DNS-encoded name for this registry.
    function getWrappedName() external view returns (bytes memory);

    /// @notice Returns the NameWrapper node (namehash).
    function getWrappedNode() external view returns (bytes32);
}
