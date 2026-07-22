// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for ENSv2-specific UniversalResolver.
/// @dev Interface selector: `0x1a6cc9f0`
interface IUniversalResolverV2 {
    /// @notice Return `true` if ENSv2.
    function isENSv2() external view returns (bool);
}
