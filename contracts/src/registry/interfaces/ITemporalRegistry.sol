// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/// @notice A registry with expirations.
/// @dev Interface selector: `0x6f537c72`
interface ITemporalRegistry is IRegistry {
    /// @notice Fetches the label expiry.
    /// @param label The label to query.
    /// @return The expiry of the label.
    function findExpiry(string calldata label) external view returns (uint64);
}
