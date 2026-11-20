// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IEmancipatableRegistry} from "./IEmancipatableRegistry.sol";
import {IPermissionedRegistry} from "./IPermissionedRegistry.sol";

/// @notice Unstable inferface for upgraded `PermissionedRegistry` functionality.
/// @dev Interface selector: `0xdd605011`
interface IPermissionedRegistryExtended is IPermissionedRegistry, IEmancipatableRegistry {
    /// @notice Determine if token is emancipated from parent control.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return `true` if the token is emancipated.
    function isTokenEmancipated(uint256 anyId) external view returns (bool);
}
