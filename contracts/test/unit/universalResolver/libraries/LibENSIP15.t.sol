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
        LibENSIP15.normalize(NameCoder.encode("A"), MockENSIP15(address(0)));
    }

    function test_normalize_isNormalized() external view {
        (bool wasNorm, bytes memory norm) = normalize("a.bb.ccc");
        assertTrue(wasNorm);
        assertEq(norm, NameCoder.encode("a.bb.ccc"));
    }

    function test_normalize_canNormalize() external view {
        (bool wasNorm, bytes memory norm) = normalize("A.Bb.cCc");
        assertFalse(wasNorm);
        assertEq(norm, NameCoder.encode("a.bb.ccc"));
    }

    function test_normalize_cannotNormalize() external {
        vm.expectRevert(abi.encodeWithSelector(IENSIP15.CannotNormalize.selector, " "));
        this.normalize(" ");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function normalize(string memory inputName) public view returns (bool, bytes memory) {
        return LibENSIP15.normalize(NameCoder.encode(inputName), ensip15);
    }
}
