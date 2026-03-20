// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IHCAInitDataParser
/// @dev Interface selector: `0xf9660ea1`
interface IHCAInitDataParser {
    function getOwnerFromInitData(bytes calldata initData) external view returns (address hcaOwner);
}
