// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IPermissionedRegistry} from "./IPermissionedRegistry.sol";

/// @dev Minimum Size of `abi.encode(Data({...}))`.
uint256 constant MIN_DATA_SIZE = 4 * 32;

/// @dev Interface for a registry that manages a locked NameWrapper name.
interface IWrapperRegistry is IPermissionedRegistry {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev Typed arguments for `initialize()`.
    struct ConstructorArgs {
        bytes32 node;
        address owner;
        uint256 ownerRoles;
    }

    /// @dev Typed arguments for NameWrapper token transfer.
    struct Data {
        string label;
        address owner;
        address resolver;
        uint256 salt;
    }

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error InvalidData();

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    function initialize(ConstructorArgs calldata args) external;

    function parentName() external view returns (bytes memory);
}
