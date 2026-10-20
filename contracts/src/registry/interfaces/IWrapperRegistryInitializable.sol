// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/// @notice Interface for initializing a `WrapperRegistry`.
/// @dev Interface selector: `0x26bb5917`
interface IWrapperRegistryInitializable {
    /// @notice Initialize the contract.
    /// @param node Namehash of this registry.
    /// @param parentRegistry The parent of this registry.
    /// @param childLabel The subdomain for this registry.
    /// @param fuses The NameWrapper fuses granted to the virtual admin.
    function initialize(
        bytes32 node,
        IRegistry parentRegistry,
        string calldata childLabel,
        uint32 fuses
    )
        external;
}
