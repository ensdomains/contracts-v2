// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {IENSIP15} from "~src/universalResolver/interfaces/IENSIP15.sol";
import {MockENSIP15} from "~test/mocks/MockENSIP15.sol";

contract MockENSIP15Test is Test {
    MockENSIP15 ensip15;

    function setUp() external {
        ensip15 = new MockENSIP15();
    }

    function test_isNormalized() external view {
        assertEq(ensip15.normalize("abc"), "abc");
    }

    function test_canNormalize() external view {
        assertEq(ensip15.normalize("ABC"), "abc");
    }

    function test_cannotNormalize() external {
        vm.expectRevert(abi.encodeWithSelector(IENSIP15.CannotNormalize.selector, " "));
        ensip15.normalize(" ");
    }
}
