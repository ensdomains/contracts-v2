// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {
    IEACGrantInitializable,
    Grant
} from "../access-control/interfaces/IEACGrantInitializable.sol";
import {InvalidOwner} from "../CommonErrors.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

/// @title UserRegistry
/// @notice UUPS-upgradeable `PermissionedRegistry` designed to be deployed as a proxy via
///         `VerifiableFactory` for user-owned subdomain registries. The constructor disables
///         initializers on the implementation contract; proxies call `initialize()` to set up the
///         admin and initial roles. Upgrade authorization requires the upgrade role in the root resource.
contract UserRegistry is
    Initializable,
    PermissionedRegistry,
    UUPSUpgradeable,
    IProxyAuthorization,
    IEACGrantInitializable
{
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Default URI renderer.
    IRegistryURIRenderer public immutable URI_RENDERER;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param labelStore The shared label database.
    /// @param uriRenderer The default URI renderer.
    /// @param namer The implementation namer.
    constructor(ILabelStore labelStore, IRegistryURIRenderer uriRenderer, address namer)
        PermissionedRegistry(
            labelStore,
            namer,
            RegistryRolesLib.ROLE_CAN_NAME | RegistryRolesLib.ROLE_CAN_NAME_ADMIN
        )
    {
        _disableInitializers();
        URI_RENDERER = uriRenderer;
    }

    /// @inheritdoc IEACGrantInitializable
    function initialize(Grant[] calldata grants) public initializer {
        __UUPSUpgradeable_init();
        emit RegistryCreated();
        for (uint256 i; i < grants.length; ++i) {
            _grantRoles(ROOT_RESOURCE, grants[i].roleBitmap, grants[i].account, false);
        }
        if (roleCount(ROOT_RESOURCE) == 0) {
            revert InvalidOwner();
        }
        _uriRenderer = URI_RENDERER;
        emit URIUpdated("", address(URI_RENDERER), address(0));
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(UUPSUpgradeable).interfaceId ||
            interfaceId == type(IProxyAuthorization).interfaceId ||
            interfaceId == type(IEACGrantInitializable).interfaceId ||
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

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Restricts UUPS upgrades to accounts holding the upgrade role on the root resource.
    /// @param newImplementation The address of the new implementation contract.
    function _authorizeUpgrade(address newImplementation)
        internal
        override
        onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE)
    {}
}
