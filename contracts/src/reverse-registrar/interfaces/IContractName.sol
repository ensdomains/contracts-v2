// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x75d0c0dc`
interface IContractName {
    /// @notice The unverified ENS name for this contract, e.g "mycontract.eth".
    ///         Should not be invoked directly.
    ///         Must be verified through ENSIP-19.
    function contractName() external view returns (string memory);
}
