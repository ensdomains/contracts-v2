// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";
import {UserRegistry} from "./UserRegistry.sol";

/// @notice UserRegistry with a fixed set of upgradeable implementations.
contract UserRegistryWithUpgradeSet is UserRegistry {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Set of upgradeable implementations.
    mapping(address impl => bool allowed) internal _upgradeable;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param labelStore The shared label database.
    /// @param uriRenderer The default URI renderer.
    /// @param namer The implementation namer.
    /// @param implementations List of upgradeable implementations.
    constructor(
        ILabelStore labelStore,
        IRegistryURIRenderer uriRenderer,
        address namer,
        address[] memory implementations
    )
        UserRegistry(labelStore, uriRenderer, namer)
    {
        for (uint256 i; i < implementations.length; ++i) {
            _upgradeable[implementations[i]] = true;
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Allow specific implementations to upgrade to this implementation.
    /// @param previousImplementation The previous implementation.
    /// @return `true` iff the previous implementation is supported.
    function canUpgradeFrom(address previousImplementation)
        external
        view
        virtual
        override
        returns (bool)
    {
        return _upgradeable[previousImplementation]; // this is the implementation, not the proxy
    }
}
