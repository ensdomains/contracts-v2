// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {LibISO8601} from "~src/utils/LibISO8601.sol";

/// @notice Minimal contract for testing LibISO8601
contract MockLibISO8601Implementer {
    using LibISO8601 for uint256;

    function toISO8601_batch(uint256[] memory timestamps) public pure returns (string[] memory) {
        string[] memory results = new string[](timestamps.length);
        for (uint256 i = 0; i < timestamps.length; ++i) {
            results[i] = timestamps[i].toISO8601();
        }
        return results;
    }

    function toISO8601(uint256 timestamp) public pure returns (string memory) {
        return timestamp.toISO8601();
    }
}
