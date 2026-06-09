// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {ContractNamer} from "~src/utils/ContractNamer.sol";
import {DelegatedContractNamer} from "~src/utils/DelegatedContractNamer.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";

contract ContractNamerTest is Test {
    ContractNamer contractNamer;
    MockDelegated delegated;

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
        delegated = new MockDelegated(contractNamer);
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(address(contractNamer), type(IContractNamer).interfaceId),
            "IContractNamer"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(delegated), type(IContractNamer).interfaceId),
            "IContractNamer"
        );
    }

    function test_isContractNamer() external view {
        assertFalse(contractNamer.isContractNamer(address(0)));
        assertTrue(contractNamer.isContractNamer(owner));

        assertFalse(delegated.isContractNamer(address(0)));
        assertTrue(delegated.isContractNamer(owner));
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


contract MockDelegated is DelegatedContractNamer {
    constructor(IContractNamer namer) DelegatedContractNamer(namer) {}
}
