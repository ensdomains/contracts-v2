// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title IHCAInitDataParser
interface IHCAInitDataParser {
    function getOwnerFromInitData(bytes calldata initData) external view returns (address hcaOwner);
}
