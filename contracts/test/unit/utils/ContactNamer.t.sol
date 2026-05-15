// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {ContractNamer} from "~src/utils/ContractNamer.sol";

contract ContractNamerTest is Test {
    ContractNamer contractNamer;

    function setUp() external {
        contractNamer = ContractNamer(
            address(
                new ERC1967Proxy(
                    address(new ContractNamer()),
                    abi.encodeCall(ContractNamer.initialize, (address(this)))
                )
            )
        );
    }

    function test_isContractNamer() external view {
        assertFalse(contractNamer.isContractNamer(address(0)));
        assertTrue(contractNamer.isContractNamer(address(this)));
    }
}
