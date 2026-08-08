// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

/// @title UserRegistry
/// @notice UUPS-upgradeable `PermissionedRegistry` designed to be deployed as a proxy via
///         `VerifiableFactory` for user-owned subdomain registries. The constructor disables
///         initializers on the implementation contract; proxies call `initialize()` to set up the
///         admin and initial roles. Upgrade authorization requires the upgrade role in the root resource.
contract UserRegistry is Initializable, PermissionedRegistry, UUPSUpgradeable, IProxyAuthorization {
    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param labelStore The shared label database.
    /// @param namer The implementation namer.
    constructor(ILabelStore labelStore, address namer)
        PermissionedRegistry(
            labelStore,
            namer,
            RegistryRolesLib.ROLE_CAN_NAME | RegistryRolesLib.ROLE_CAN_NAME_ADMIN
        )
    {
        // This disables initialization for the implementation contract
        _disableInitializers();
    }

    /// @notice Initialize the contract.
    /// @param rootAccount Account granted root roles.
    /// @param roleBitmap The roles granted to `rootAccount`.
    /// @param calls The calldata that avoids permission checks.
    function initialize(address rootAccount, uint256 roleBitmap, bytes[] calldata calls)
        public
        initializer
    {
        __UUPSUpgradeable_init();
        emit RegistryCreated();
        _grantRoles(ROOT_RESOURCE, roleBitmap, rootAccount, false);
        multicall(calls);
    }

    /// @inheritdoc IERC165
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
    /// @return allowed Always `true` for implementations in this registry family.
    function canUpgradeFrom(
        address /* previousImplementation */
    )
        external
        pure
        virtual
        override
        returns (bool allowed)
    {
        return true;
    }

    /// @dev Restricts UUPS upgrades to accounts holding the upgrade role on the root resource.
    /// @param newImplementation The address of the new implementation contract.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE)
    {}

    /// @dev Avoid permission checks during initialization.
    function _checkRoles(uint256 resource, uint256 roleBitmap, address account)
        internal
        view
        override
    {
        if (!_isInitializing()) {
            super._checkRoles(resource, roleBitmap, account);
        }
    }

    /// @dev Avoid permission checks during initialization.
    function _checkCanGrantRoles(uint256 resource, uint256 roleBitmap, address account)
        internal
        view
        override
    {
        if (!_isInitializing()) {
            super._checkCanGrantRoles(resource, roleBitmap, account);
        }
    }

    /// @dev Avoid permission checks during initialization.
    function _checkCanRevokeRoles(uint256 resource, uint256 roleBitmap, address account)
        internal
        view
        override
    {
        if (!_isInitializing()) {
            super._checkCanRevokeRoles(resource, roleBitmap, account);
        }
    }
}
