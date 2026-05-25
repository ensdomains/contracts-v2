// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Basic interface for Hidden Contract Account ownership lookup.
/// @dev Interface selector: `0x442b172c`
interface IHCAFactoryBasic {
    /// @notice Returns the account owner of the given HCA.
    /// @dev Returns zero when the queried address is not a recorded HCA.
    /// @param hca The HCA to get the account owner of.
    /// @return The account owner of the given HCA.
    function getAccountOwner(address hca) external view returns (address);
}
