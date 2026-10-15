// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IChainlinkAggregator} from "~src/registrar/interfaces/IChainlinkAggregator.sol";

contract MockChainlinkAggregator is IChainlinkAggregator {
    int256 public immutable ANSWER;
    uint256 public immutable MAX_AGE;
    uint8 public immutable DECIMALS;
    constructor(int256 answer, uint256 maxAge, uint8 _decimals) {
        ANSWER = answer;
        MAX_AGE = maxAge;
        DECIMALS = _decimals;
    }
    function latestRoundData()
        external
        view
        returns (
            uint80 roundId,
            int256 answer,
            uint256 startedAt,
            uint256 updatedAt,
            uint80 answeredInRound
        )
    {
        return (0, ANSWER, 0, block.timestamp - MAX_AGE, 0);
    }
    function decimals() external view returns (uint8) {
        return DECIMALS;
    }
}
