// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {MockENSIP15} from "~test/mocks/MockENSIP15.sol";

contract MockENSIP15Test is Test {
    MockENSIP15 ensip15;

    function setUp() external {
        ensip15 = new MockENSIP15();
    }

    function test_abc() external view {
        assertEq(ensip15.normalize("abc"), "abc");
    }

    function test_ABC() external view {
        assertEq(ensip15.normalize("ABC"), "abc");
    }
}
