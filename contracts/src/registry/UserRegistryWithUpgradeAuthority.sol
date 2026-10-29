// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";
import {UserRegistry} from "./UserRegistry.sol";

/// @notice A UserRegistry for fixing untrustable implementations with external authority.
contract UserRegistryWithUpgradeAuthority is UserRegistry {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @dev The upgrade authority.
    IAddressSet private immutable _AUTHORITY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param labelStore The shared label database.
    /// @param uriRenderer The default URI renderer.
    /// @param namer The implementation namer.
    /// @param authority The upgrade authority.
    constructor(
        ILabelStore labelStore,
        IRegistryURIRenderer uriRenderer,
        address namer,
        IAddressSet authority
    )
        UserRegistry(labelStore, uriRenderer, namer)
    {
        _AUTHORITY = authority;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Declares this implementation as an eligible verifiable proxy upgrade target.
    /// @param {previousImplementation} Ignored.
    /// @return `true` iff the authority authorizes the upgrade.
    function canUpgradeFrom(
        address /* previousImplementation */
    )
        external
        view
        override
        returns (bool)
    {
        return _AUTHORITY.includes(msg.sender);
    }
}
