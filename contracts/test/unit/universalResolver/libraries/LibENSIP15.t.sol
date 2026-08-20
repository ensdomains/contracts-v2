// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {IENSIP15} from "~src/universalResolver/interfaces/IENSIP15.sol";
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
        (bool wasNorm, bytes memory name) = norm("");
        assertTrue(wasNorm);
        assertEq(name, NameCoder.encode(""));
    }

    function test_normalize_dot() external {
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsEmpty.selector));
        this.norm(".");
    }

    function test_normalize_leadingEmpty() external {
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsEmpty.selector));
        this.norm(".eth");
    }

    function test_normalize_containsEmpty() external {
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsEmpty.selector));
        this.norm("test..eth");
    }

    function test_normalize_trailingEmpty() external {
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsEmpty.selector));
        this.norm("eth.");
    }

    function test_normalize_tooLong() external {
        string memory name = new string(256);
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsTooLong.selector, name));
        this.norm(name);
    }

    function test_normalize_isNormalized() external view {
        (bool wasNorm, bytes memory name) = norm("a.bb.ccc");
        assertTrue(wasNorm);
        assertEq(name, NameCoder.encode("a.bb.ccc"));
    }

    function test_normalize_canNormalize() external view {
        (bool wasNorm, bytes memory name) = norm("A.Bb.cCc");
        assertFalse(wasNorm);
        assertEq(name, NameCoder.encode("a.bb.ccc"));
    }

    function test_normalize_cannotNormalize() external {
        vm.expectRevert(abi.encodeWithSelector(IENSIP15.CannotNormalize.selector, " "));
        this.norm(" ");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function norm(string memory name) public view returns (bool, bytes memory) {
        return LibENSIP15.normalize(name, ensip15);
    }
}
