// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {LibLabel} from "~src/utils/LibLabel.sol";

contract LibLabelTest is Test {
    function test_known() external pure {
        uint256 id = LibLabel.id("abc");
        assertEq(id, 0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58fa12d6c45);
        assertEq(
            LibLabel.withVersion(id, 0), //                           ________
            0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58f00000000
        );
        assertEq(
            LibLabel.withVersion(id, 0xaaaaaaaa), //                  ________
            0x4e03657aea45a94fc7d47ba826c8d667c0d1e6e33a64a036ec44f58faaaaaaaa
        );
    }

    function test_id(string memory label) external pure {
        assertEq(LibLabel.id(label), uint256(keccak256(bytes(label)))); // labelhash()
    }

    function test_withVersion(uint256 id, uint32 version) external pure {
        assertEq(LibLabel.withVersion(id, version) >> 32, id >> 32, "id");
        assertEq(uint32(LibLabel.withVersion(id, version)), version, "version");
    }

    function test_collisions(string memory a, string memory b) external pure {
        uint256 x = LibLabel.id(a);
        uint256 y = LibLabel.id(b);
        if (x != y && LibLabel.withVersion(x, 0) == LibLabel.withVersion(y, 0)) {
            assertEq(a, b);
        }
    }
}
