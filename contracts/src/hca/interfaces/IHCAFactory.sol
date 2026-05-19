// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Interface for the HCA factory.
/// @dev Interface selector: `0x519b41ac`
interface IHCAFactory {
    /// @notice Designates an existing SCA as the caller's HCA.
    /// @param hca The existing SCA to designate.
    function setAccount(address hca) external;

    /// @notice Returns the implementation accepted by HCA upgrade guards.
    function getImplementation() external view returns (address);

    /// @notice Returns whether an implementation is approved for HCA deployment and upgrades.
    /// @param implementation The implementation address to check.
    /// @return approved Whether the implementation is approved.
    function approvedImplementations(address implementation) external view returns (bool approved);

    /// @notice Returns the owner recorded for a deployed HCA proxy.
    /// @param hca The HCA proxy address to look up.
    /// @return hcaOwner The owner address, or `address(0)` if the HCA is not registered.
    function getAccountOwner(address hca) external view returns (address hcaOwner);
}
