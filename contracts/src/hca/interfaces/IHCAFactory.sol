// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev Interface selector: `0xeeda186e`
interface IHCAFactory {
    function getImplementation() external view returns (address);

    function getAccountOwner(address hca) external view returns (address);
}
