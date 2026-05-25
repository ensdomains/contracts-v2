// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @dev Interface selector: `0x6f3ff726`
interface IContractNamer {
    /// @notice Determine if an account is authorized to name this contract.
    ///         Called by reverse registrars.
    /// @param namer The address to check.
    /// @return `true` if authorized.
    function isContractNamer(address namer) external view returns (bool);
}
