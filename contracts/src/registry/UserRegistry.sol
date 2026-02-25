// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {InvalidOwner} from "../CommonErrors.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

import {IRegistryMetadata} from "./interfaces/IRegistryMetadata.sol";
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

/// @title UserRegistry
/// @dev A user registry that inherits from PermissionedRegistry and is upgradeable using the UUPS pattern.
/// This contract is designed to be deployed via the VerifiableFactory.
contract UserRegistry is Initializable, PermissionedRegistry, UUPSUpgradeable {
    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        IHCAFactoryBasic hcaFactory_,
        IRegistryMetadata metadataProvider_
    ) PermissionedRegistry(hcaFactory_, metadataProvider_, _msgSender(), 0) {
        // This disables initialization for the implementation contract
        _disableInitializers();
    }

    /// @dev Initializes the UserRegistry contract.
    /// @param admin The address that will be set as the admin with upgrade privileges.
    /// @param roleBitmap The roles to grant to `admin`.
    function initialize(address admin, uint256 roleBitmap) public initializer {
        if (admin == address(0)) {
            revert InvalidOwner();
        }
        // metadata provider is set immutably in constructor
        // Grant roles to the admin
        _grantRoles(ROOT_RESOURCE, roleBitmap, admin, false);
    }

    /// @dev See {IERC165-supportsInterface}.
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(UUPSUpgradeable).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @dev Function that authorizes an upgrade to a new implementation.
    ///      Only accounts with the _ROLE_UPGRADE_ADMIN role can upgrade the contract.
    /// @param newImplementation The address of the new implementation.
    function _authorizeUpgrade(
        address newImplementation
    ) internal override onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE) {
        // Authorization is handled by the onlyRootRoles modifier
    }
}
