// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {InvalidOwner} from "../CommonErrors.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
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

    /// @param hcaFactory The HCA factory.
    /// @param labelStore The shared label database.
    /// @param namer The implementation namer.
    constructor(IHCAFactoryBasic hcaFactory, ILabelStore labelStore, address namer)
        PermissionedRegistry(
            hcaFactory,
            labelStore,
            namer,
            RegistryRolesLib.ROLE_CAN_NAME | RegistryRolesLib.ROLE_CAN_NAME_ADMIN
        )
    {
        // This disables initialization for the implementation contract
        _disableInitializers();
    }

    /// @notice Initializes a proxy instance of `UserRegistry`.
    /// @dev Grants the supplied role bitmap to `rootAccount` on the root resource.
    ///      Reverts if the zero address.
    /// @param rootAccount Account granted root roles.
    /// @param roleBitmap The role bitmap granted to `rootAccount`.
    function initialize(address rootAccount, uint256 roleBitmap) public initializer {
        if (rootAccount == address(0)) {
            revert InvalidOwner();
        }
        emit RegistryCreated();
        _grantRoles(ROOT_RESOURCE, roleBitmap, rootAccount, false);
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
}
