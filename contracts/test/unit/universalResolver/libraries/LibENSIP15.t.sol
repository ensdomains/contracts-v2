// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {LibENSIP15} from "~src/universalResolver/libraries/LibENSIP15.sol";
import {MockENSIP15} from "~test/mocks/MockENSIP15.sol";

contract LibENSIP15Test is Test {
    MockENSIP15 ensip15;

    function setUp() external {
        ensip15 = new MockENSIP15();
    }

    function test_normalize_nullImpl() external {
        vm.expectRevert();
        this._callWithNullImpl();
    }

    function _callWithNullImpl() external view {
        LibENSIP15.normalize("A", MockENSIP15(address(0)));
    }

    function test_normalize_empty() external view {
        (bool wasNorm, bytes memory name) = LibENSIP15.normalize("", ensip15);
        assertTrue(wasNorm);
        assertEq(name, NameCoder.encode(""));
    }

    function test_normalize_ETH() external view {
        (bool wasNorm, bytes memory name) = LibENSIP15.normalize("ETH", ensip15);
        assertFalse(wasNorm);
        assertEq(name, NameCoder.encode("eth"));
    }

    function test_normalize_TEST_eth() external view {
        (bool wasNorm, bytes memory name) = LibENSIP15.normalize("TEST.eth", ensip15);
        assertFalse(wasNorm);
        assertEq(name, NameCoder.encode("test.eth"));
    }
}
