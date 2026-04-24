// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev Interface selector: `0xeeda186e`
interface IHCAFactory {
    /// @notice Returns the account implementation used by the factory.
    function getImplementation() external view returns (address);

    /// @notice Returns the owner for an HCA account, or zero if it cannot be read.
    /// @param hca The HCA account to inspect.
    /// @return The account owner, or zero for incompatible accounts.
    function getAccountOwner(address hca) external view returns (address);
}
