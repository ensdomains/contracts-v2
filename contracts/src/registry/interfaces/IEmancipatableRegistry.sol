// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/// @notice A registry with emancipatable children.
/// @dev Interface selector: `0xd685ea5d`
interface IEmancipatableRegistry is IRegistry {
    /// @notice Determine if label is emancipated from parent control.
    /// @param label The label to check.
    /// @return `true` if the label is emancipated.
    function isChildEmancipated(string calldata label) external view returns (bool);
}
