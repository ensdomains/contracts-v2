// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @dev Interface selector: `0xeeda186e`
interface IHCAFactory {
    /// @notice Returns the implementation used for newly deployed HCA proxies.
    function getImplementation() external view returns (address);

    /// @notice Returns the owner recorded for a deployed HCA proxy.
    /// @param hca The HCA proxy address to look up.
    /// @return hcaOwner The owner address, or `address(0)` if the HCA is not registered.
    function getAccountOwner(address hca) external view returns (address hcaOwner);
}
