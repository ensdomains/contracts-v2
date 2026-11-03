// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {
    IEACGrantInitializable,
    Grant
} from "../access-control/interfaces/IEACGrantInitializable.sol";
import {InvalidOwner} from "../CommonErrors.sol";
import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {
    AbstractUpgradeablePermissionedRegistry
} from "./AbstractUpgradeablePermissionedRegistry.sol";
import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";

/// @notice Upgradeable `PermissionedRegistry` for user-owned subdomain registries.
contract UserRegistry is AbstractUpgradeablePermissionedRegistry, IEACGrantInitializable {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Default URI renderer.
    IRegistryURIRenderer public immutable URI_RENDERER;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param upgradeSet Set of approved upgrade implementations.
    /// @param labelStore The shared label database.
    /// @param uriRenderer The default URI renderer.
    /// @param namer The implementation namer.
    constructor(
        IAddressSet upgradeSet,
        ILabelStore labelStore,
        IRegistryURIRenderer uriRenderer,
        address namer
    )
        AbstractUpgradeablePermissionedRegistry(upgradeSet, labelStore, namer)
    {
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
            interfaceId == type(IEACGrantInitializable).interfaceId ||
            super.supportsInterface(interfaceId);
    }
}
