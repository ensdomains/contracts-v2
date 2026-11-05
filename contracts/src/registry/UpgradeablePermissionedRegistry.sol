// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

/// @notice An upgradeable `PermissionedRegistry`.
/// 
/// The constructor disables initializers on the implementation contract and
/// stores the list of upgradeable implementations in the implementation.
///
/// Upgrades requires `ROLE_UPGRADE` on root and the implementation must
/// be approved by `_isUpgradeApproved()` which defaults to `UPGRADE_SET`.
/// If `UPGRADE_SET` is null, allows any upgrade to any implementation.
///
contract UpgradeablePermissionedRegistry is
    Initializable,
    PermissionedRegistry,
    UUPSUpgradeable,
    IProxyAuthorization
{
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev Internal storage for implementation-use only.
    struct Storage {
        mapping(address implementation => bool can) canUpgradeFrom;
    }

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set of approved upgrade implementations.
    IAddressSet public immutable UPGRADE_SET;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Upgrade target is not approved.
    /// @dev Error selector: `0xf74d7dd0`
    /// @param implementation Disallowed implementation address.
    error UpgradeTargetNotApproved(address implementation);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param labelStore The shared label database.
    /// @param namer The implementation namer.
    /// @param upgradeSet Set of approved upgrade implementations.
    /// @param upgradeable List of upgradeable implementations.
    constructor(
        ILabelStore labelStore,
        address namer,
        IAddressSet upgradeSet,
        address[] memory upgradeable
    )
        PermissionedRegistry(
            labelStore,
            namer,
            RegistryRolesLib.ROLE_CAN_NAME | RegistryRolesLib.ROLE_CAN_NAME_ADMIN
        )
    {
        _disableInitializers();
        UPGRADE_SET = upgradeSet;
        Storage storage s = _storage();
        for (uint256 i; i < upgradeable.length; ++i) {
            s.canUpgradeFrom[upgradeable[i]] = true;
        }
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
    /// @dev Upgrade authorization is also enforced during `_authorizeUpgrade()`.
    /// @param previousImplementation Previous implementation address.
    /// @return `true` if `previousImplementation` can be upgraded.
    function canUpgradeFrom(address previousImplementation)
        external
        view
        virtual
        override
        returns (bool)
    {
        return _storage().canUpgradeFrom[previousImplementation];
    }

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

    /// @dev Access internal storage.
    ///      Uses slot 1 which is `ERC1155Singleton._operatorApprovals`.
    ///      This is safe because it is only used by the implementation.
    function _storage() internal pure returns (Storage storage s) {
        assembly ("memory-safe") {
            s.slot := 1
        }
    }
}
