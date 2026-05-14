// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {ContractNamer} from "~src/utils/ContractNamer.sol";

contract ContractNamerTest is Test {
    ContractNamer contractNamer;

    function setUp() external {
        contractNamer = new ContractNamer(address(this));
    }

    function test_isContractNamer() external view {
        assertFalse(contractNamer.isContractNamer(address(0)));
        assertTrue(contractNamer.isContractNamer(address(this)));
    }
}
