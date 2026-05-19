// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IHCAInitDataParser
/// @dev Interface selector: `0xf9660ea1`
interface IHCAInitDataParser {
    /// @notice Extracts the HCA owner from initialization data.
    /// @param initData The initialization data to parse.
    /// @return hcaOwner The owner encoded in the initialization data.
    function getOwnerFromInitData(bytes calldata initData) external view returns (address hcaOwner);
}
