// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";

import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";

/// @dev Mixin for supporting an upgrade authority.
abstract contract DelegatedUpgradeAuthority is IProxyAuthorization {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    //////////////////////////////////////////////////////////////////////// 

    /// @dev The upgrade authority.
    IAddressSet internal immutable _UPGRADE_AUTHORITY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param upgradeAuthority The upgrade authority.
    constructor(IAddressSet upgradeAuthority) {
        _UPGRADE_AUTHORITY = upgradeAuthority;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Declares this implementation as a verifiable proxy upgrade target.
    /// @param {previousImplementation} Ignored.
    /// @return `true` iff the authority authorizes the upgrade.
    function canUpgradeFrom(
        address /*previousImplementation*/
    )
        external
        view
        virtual
        override
        returns (bool)
    {
        return address(_UPGRADE_AUTHORITY) != address(0) && _UPGRADE_AUTHORITY.includes(msg.sender); // argument is the proxy, sender is the newImplementation
    }
}
