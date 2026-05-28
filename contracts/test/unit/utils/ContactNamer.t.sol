// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {ContractNamer} from "~src/utils/ContractNamer.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";

contract ContractNamerTest is Test {
    ContractNamer contractNamer;
    address owner = makeAddr("owner");

    function setUp() external {
        contractNamer = ContractNamer(
            address(
                new ERC1967Proxy(
                    address(new ContractNamer()),
                    abi.encodeCall(ContractNamer.initialize, (owner))
                )
            )
        );
    }

    function test_isContractNamer() external view {
        assertFalse(contractNamer.isContractNamer(address(0)));
        assertTrue(contractNamer.isContractNamer(owner));
    }

    function test_upgrade() external {
        MockUpgrade c = new MockUpgrade();
        vm.prank(owner);
        contractNamer.upgradeToAndCall(address(c), "");
        assertTrue(contractNamer.isContractNamer(address(1)));
    }

    function test_upgrade_notAuthorized() external {
        MockUpgrade c = new MockUpgrade();
        vm.expectRevert();
        contractNamer.upgradeToAndCall(address(c), "");
    }
}


contract MockUpgrade is UUPSUpgradeable, IContractNamer {
    function isContractNamer(address namer) external pure returns (bool) {
        return namer == address(1);
    }
    function _authorizeUpgrade(address) internal override {}
}
