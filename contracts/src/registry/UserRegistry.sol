// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {InvalidOwner} from "../CommonErrors.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {IRegistryMetadata} from "./interfaces/IRegistryMetadata.sol";
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

/// @title UserRegistry
/// @notice UUPS-upgradeable `PermissionedRegistry` designed to be deployed as a proxy via
///         `VerifiableFactory` for user-owned subdomain registries. The constructor disables
///         initializers on the implementation contract; proxies call `initialize()` to set up the
///         admin and initial roles. Upgrade authorization requires the upgrade role in the root resource.
contract UserRegistry is Initializable, PermissionedRegistry, UUPSUpgradeable {
    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Creates the UserRegistry implementation.
    /// @param hcaFactory The HCA factory.
    /// @param metadataProvider The metadata provider.
    constructor(
        IHCAFactoryBasic hcaFactory,
        IRegistryMetadata metadataProvider
    ) PermissionedRegistry(hcaFactory, metadataProvider, address(0), 0) {
        // This disables initialization for the implementation contract
        _disableInitializers();
    }

    /// @notice Initializes a proxy instance of `UserRegistry`.
    /// @dev Grants the supplied role bitmap to `admin` on the root resource. Reverts if `admin`
    ///      is the zero address.
    /// @param admin The address that will receive the specified roles.
    /// @param roleBitmap The role bitmap to grant to `admin`.
    function initialize(address admin, uint256 roleBitmap) public initializer {
        if (admin == address(0)) {
            revert InvalidOwner();
        }
        emit RegistryCreated();
        _grantRoles(ROOT_RESOURCE, roleBitmap, admin, false);
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(UUPSUpgradeable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @dev Restricts UUPS upgrades to accounts holding the upgrade role on the root resource.
    /// @param newImplementation The address of the new implementation contract.
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE) {}
}
