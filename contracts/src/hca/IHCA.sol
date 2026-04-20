// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev Interface selector: `0x893d20e8`
interface IHCA {
    /// @notice Returns the owner of the account.
    function getOwner() external view returns (address);
}
