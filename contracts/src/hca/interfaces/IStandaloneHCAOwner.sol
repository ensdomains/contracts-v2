// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title Standalone HCA Owner Interface
/// @notice Minimal owner view exposed by a standalone HCA account.
/// @dev Interface selector: `0x8da5cb5b`
interface IStandaloneHCAOwner {
    /// @notice Returns the account owner.
    function owner() external view returns (address);
}
