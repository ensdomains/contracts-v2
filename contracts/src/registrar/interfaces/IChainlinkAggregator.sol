// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// https://docs.chain.link/chainlink-local/api-reference/v0.2.3/aggregator-v2-v3-interface
// https://github.com/smartcontractkit/chainlink-evm/blob/develop/contracts/src/v0.8/shared/interfaces/AggregatorInterface.sol
// https://github.com/smartcontractkit/chainlink-evm/blob/develop/contracts/src/v0.8/shared/interfaces/AggregatorV3Interface.sol

/// @dev Interface selector: `0x61eebeaa`
interface IChainlinkAggregator {
    /// @notice Number of decimals used in `latestAnswer()`.
    function decimals() external view returns (uint8);

    /// @notice Gets the latest answer from the aggregator.
    function latestAnswer() external view returns (int256);

    // /// @notice Gets the latest round data.
    // /// @return roundId The latest round ID.
    // /// @return answer The latest answer.
    // /// @return startedAt The timestamp when the latest round started.
    // /// @return updatedAt The timestamp when the latest round was updated.
    // /// @return answeredInRound The round ID in which the latest answer was computed.
    // function latestRoundData()
    //     external
    //     view
    //     returns (
    //         uint80 roundId,
    //         int256 answer,
    //         uint256 startedAt,
    //         uint256 updatedAt,
    //         uint80 answeredInRound
    //     );
}
