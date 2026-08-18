// SPDX-License-Identifier: MIT
pragma solidity >=0.8.24;

import {BytesUtils} from "@ens/contracts/utils/BytesUtils.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {IENSIP15} from "../interfaces/IENSIP15.sol";

/// @dev Library for normalizing literal names into normalized DNS-encoded names.
library LibENSIP15 {
    /// @dev Normalize a name according to ENSIP-15.
    /// @param ensName Literal name to normalize, eg. `nick.eth`.
    /// @param ensip15 ENSIP-15 Normalization implementation.
    /// @return wasNormalized `true` if `ensName` was normalized.
    /// @return name Normalized DNS-encoded name, eg. `\x04nick\x03eth\x00` or null if not normalizable.
    function normalize(string memory ensName, IENSIP15 ensip15)
        internal
        view
        returns (bool wasNormalized, bytes memory name)
    {
        wasNormalized = true;
        uint256 size = bytes(ensName).length;
        if (size == 0) {
            return (true, hex"00");
        }
        uint256 labelCount = 1;
        for (uint256 i; i < size; ++i) {
            if (bytes(ensName)[i] == ".") {
                ++labelCount;
            }
        }
        name = new bytes(labelCount * 256 + 1);
        uint256 dst;
        assembly {
            dst := add(name, 32)
        }
        uint256 prev;
        while (prev < size) {
            uint256 next = BytesUtils.find(bytes(ensName), prev, size - prev, ".");
            if (next > size) {
                next = size; // last label
            }
            bytes memory label = BytesUtils.substring(bytes(ensName), prev, next - prev);
            string memory norm = ensip15.normalize(string(label));
            NameCoder.assertLabelSize(norm);
            wasNormalized = wasNormalized && keccak256(label) == keccak256(bytes(norm));
            assembly {
                let n := mload(norm)
                mstore8(dst, n) // write length
                mcopy(add(dst, 1), add(norm, 32), n) // write normalized label
                dst := add(dst, add(n, 1))
            }
            prev = next + 1;
        }
        assembly {
            mstore(name, sub(dst, add(name, 31))) // truncate
        }
    }
}
