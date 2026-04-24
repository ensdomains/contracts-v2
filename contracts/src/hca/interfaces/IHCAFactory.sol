// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @notice Factory interface for HCA account lookup and implementation discovery.
/// @dev Interface selector: `0xeeda186e`
interface IHCAFactory {
    /// @notice Returns the account implementation used by new HCA proxies.
    function getImplementation() external view returns (address);

    /// @notice Returns the owner recorded for an HCA proxy.
    /// @param hca The HCA proxy address to inspect.
    /// @return The recorded owner, or zero if the account is not known to the factory.
    function getAccountOwner(address hca) external view returns (address);
}
