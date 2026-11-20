// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/// @dev Interface selector: `0x234cdbef`
interface IEmancipatableRegistry is IRegistry {
    /// @notice Determine if label is emancipated.
    /// @param label The label to check.
    /// @return `true` if the label is emancipated.
    function isTokenEmancipated(string calldata label) external view returns (bool);
}
