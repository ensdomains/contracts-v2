// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IENSIP15} from "~src/universalResolver/interfaces/IENSIP15.sol";

contract MockENSIP15 is IENSIP15 {
    /// @dev ASCII case-folding: [A-Z] => [a-z].
    ///      Revert `CannotNormalize` if contains a space.
    function normalize(string memory label) external pure returns (string memory) {
        bytes memory v = abi.encodePacked(label);
        for (uint256 i; i < v.length; ++i) {
            bytes1 ch = v[i];
            if (ch >= "A" && ch <= "Z") {
                v[i] = bytes1(uint8(ch) + 32);
            } else if (ch == " ") {
                revert CannotNormalize(label);
            }
        }
        return string(v);
    }
}
