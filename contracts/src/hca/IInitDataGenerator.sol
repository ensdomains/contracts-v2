// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IInitDataGenerator
/// @notice Interface for contracts that generate account-specific initialization data
/// @dev Interface selector: `0xa074f44d`
interface IInitDataGenerator {
    /// @notice Generates account-specific initialization data
    /// @param owner The account owner address
    /// @return The generated initialization data
    function generateInitData(address owner) external view returns (bytes memory);
}
