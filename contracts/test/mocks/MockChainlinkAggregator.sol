// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IChainlinkAggregator} from "~src/registrar/interfaces/IChainlinkAggregator.sol";

contract MockChainlinkAggregator is IChainlinkAggregator {
    int256 public immutable ANSWER;
    uint8 public immutable DECIMALS;
    constructor(int256 answer, uint8 _decimals) {
        ANSWER = answer;
        DECIMALS = _decimals;
    }
    function latestAnswer() external view returns (int256) {
        return ANSWER;
    }
    function decimals() external view returns (uint8) {
        return DECIMALS;
    }
}
