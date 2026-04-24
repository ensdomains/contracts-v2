// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Parser for extracting HCA owners from account initialization data.
/// @dev Interface selector: `0xf9660ea1`
interface IHCAInitDataParser {
    /// @notice Returns the owner encoded in account initialization data.
    /// @param initData The account initialization data.
    /// @return hcaOwner The owner parsed from the initialization data.
    function getOwnerFromInitData(bytes calldata initData) external view returns (address hcaOwner);
}
