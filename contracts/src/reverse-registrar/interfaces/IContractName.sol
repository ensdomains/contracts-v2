// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0xe52158e2`
interface IContractName {
    /// @notice The unverified ENS name for this contract.
    ///         Should not be invoked directly.
    ///         Must be verified through ENSIP-19.
    /// @return The unverified ENS name for this contract, eg. "mycontract.eth".
    function ensContractName() external view returns (string memory);
}
