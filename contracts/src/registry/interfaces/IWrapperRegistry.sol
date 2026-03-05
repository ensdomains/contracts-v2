// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IPermissionedRegistry} from "./IPermissionedRegistry.sol";
import {IRegistry} from "./IRegistry.sol";

/// @notice Interface for a registry that manages a locked NameWrapper name.
/// @dev Interface selector: `0x444b831d`
interface IWrapperRegistry is IPermissionedRegistry {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev Typed arguments for `initialize()`.
    struct ConstructorArgs {
        /// @dev Namehash of this registry.
        bytes32 node;
        /// @dev Parent registry of this registry.
        IRegistry parentRegistry;
        /// @dev Subdomain of `parentRegistry` that corresponds to this registry.
        string childLabel;
        /// @dev Address that will control this registry.
        address admin;
        /// @dev The roles assigned to `admin`.
        uint256 roleBitmap;
    }

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    function initialize(ConstructorArgs calldata args) external;
}
