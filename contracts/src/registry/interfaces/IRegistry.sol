// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistryEvents} from "./IRegistryEvents.sol";

/// @dev Interface selector: `0xd1011f61`
interface IRegistry is IRegistryEvents {
    /// @dev Fetches the registry for a label.
    /// @param label The label to resolve.
    /// @return The address of the registry for this label, or `address(0)` if none exists.
    function getSubregistry(string calldata label) external view returns (IRegistry);

    /// @dev Fetches the resolver responsible for the specified label.
    /// @param label The label to fetch a resolver for.
    /// @return resolver The address of a resolver responsible for this label, or `address(0)` if none exists.
    function getResolver(string calldata label) external view returns (address);
}
