// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

/// @dev Abstract upgradeable `PermissionedRegistry`.
/// 
/// The constructor disables initializers on the implementation contract.
///
/// Upgrades requires `ROLE_UPGRADE` on root and the implementation must
/// be approved by `_isUpgradeApproved()` which defaults to `UPGRADE_SET`.
///
abstract contract AbstractUpgradeablePermissionedRegistry is
    Initializable,
    PermissionedRegistry,
    UUPSUpgradeable,
    IProxyAuthorization
{
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set of approved upgrade implementations.
    IAddressSet public immutable UPGRADE_SET;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Upgrade target is not approved for `WrapperRegistry` proxies.
    /// @dev Error selector: `0xf74d7dd0`
    /// @param implementation The disallowed implementation address.
    error UpgradeTargetNotApproved(address implementation);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param upgradeSet Set of approved upgrade implementations.
    /// @param labelStore The shared label database.
    /// @param namer The implementation namer.
    constructor(IAddressSet upgradeSet, ILabelStore labelStore, address namer)
        PermissionedRegistry(
            labelStore,
            namer,
            RegistryRolesLib.ROLE_CAN_NAME | RegistryRolesLib.ROLE_CAN_NAME_ADMIN
        )
    {
        _disableInitializers();
        UPGRADE_SET = upgradeSet;
    }

    /// @inheritdoc PermissionedRegistry
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(UUPSUpgradeable).interfaceId ||
            interfaceId == type(IProxyAuthorization).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Declares this implementation as an eligible verifiable proxy upgrade target.
    /// @dev Upgrade authorization is still enforced by the current implementation during the UUPS
    ///      upgrade call.
    /// @param {previousImplementation} Ignored.
    /// @return allowed Always `false` as this is the first implementation
    function canUpgradeFrom(
        address /* previousImplementation */
    )
        external
        pure
        virtual
        override
        returns (bool allowed)
    {}

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Override: require `ROLE_UPGRADE` and implementation must be approved.
    function _authorizeUpgrade(address newImplementation)
        internal
        view
        override
        onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE)
    {
        if (!_isUpgradeApproved(newImplementation)) {
            revert UpgradeTargetNotApproved(newImplementation);
        }
    }

    /// @dev Determine if the upgrade is allowed.
    function _isUpgradeApproved(address newImplementation) internal view virtual returns (bool) {
        IAddressSet upgradeSet = UPGRADE_SET;
        return address(upgradeSet) == address(0) || upgradeSet.includes(newImplementation);
    }
}
