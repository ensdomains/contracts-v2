// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev Interface selector: `0xfa544161`
interface IK1Validator {
    /// @notice Returns the owner configured for a smart account.
    /// @param smartAccount The smart account to inspect.
    /// @return The account owner.
    function getOwner(address smartAccount) external view returns (address);
}
