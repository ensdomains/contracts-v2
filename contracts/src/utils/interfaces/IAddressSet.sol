// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x1aedefda`
interface IAddressSet {
    /// @notice Check if `addr` is included in the set.
    /// @param addr The address to check.
    /// @return `true` if included.
    function includes(address addr) external view returns (bool);
}
