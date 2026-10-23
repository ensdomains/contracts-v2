// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/// @notice Interface for initializing a `WrapperRegistry`.
/// @dev Interface selector: `0x6910e334`
interface IWrapperRegistryInitializable {
    /// @notice Initialize the contract.
    /// @param node Namehash of this registry.
    /// @param parentRegistry The parent of this registry.
    function initialize(bytes32 node, IRegistry parentRegistry) external;
}
