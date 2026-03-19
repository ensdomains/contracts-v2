// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

interface IK1Validator {
    function getOwner(address smartAccount) external view returns (address);
}
