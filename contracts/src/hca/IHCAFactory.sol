// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IHCAFactory {
    function getImplementation() external view returns (address);

    function getAccountOwner(address hca) external view returns (address);
}
