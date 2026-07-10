// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x8da5cb5b`
interface IHCA {
    /// @notice Returns the underlying HCA owner.
    function owner() external view returns (address);
}
