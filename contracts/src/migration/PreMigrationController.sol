// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {IPreMigrationController} from "./interfaces/IPreMigrationController.sol";

/// @title PreMigrationController
/// @notice Controller that owns pre-migrated names. Migration controllers call claim() to complete migration on behalf of users.
contract PreMigrationController is
    IPreMigrationController,
    IERC1155Receiver,
    ERC165,
    EnhancedAccessControl
{
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice Role for migration controllers to call claim()
    uint256 public constant ROLE_MIGRATION_CONTROLLER = 1 << 0;

    IPermissionedRegistry public immutable ETH_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    event NameClaimed(
        string indexed label,
        address indexed owner,
        address subregistry,
        address resolver
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0x34767f82`
    error NameNotOwned(string label, address actualOwner);
    /// @dev Error selector: `0x407c156a`
    error NameExpired(string label);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        IPermissionedRegistry ethRegistry,
        IHCAFactoryBasic hcaFactory,
        address ownerAddress,
        uint256 ownerRoles
    ) HCAEquivalence(hcaFactory) {
        ETH_REGISTRY = ethRegistry;
        _grantRoles(ROOT_RESOURCE, ownerRoles, ownerAddress, false);
    }

    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, EnhancedAccessControl, IERC165) returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            interfaceId == type(IPreMigrationController).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IPreMigrationController
    /// @dev Sets subregistry/resolver and transfers ownership to the new owner.
    ///      Pre-migrated names have ROLES.ALL, so all roles transfer with the token.
    function claim(
        string calldata label,
        address owner,
        IRegistry subregistry,
        address resolver
    ) external onlyRootRoles(ROLE_MIGRATION_CONTROLLER) {
        IPermissionedRegistry.State memory state = ETH_REGISTRY.getState(LibLabel.id(label));

        if (state.expiry == 0 || state.expiry <= block.timestamp) {
            revert NameExpired(label);
        }

        address currentOwner = ETH_REGISTRY.ownerOf(state.tokenId);
        if (currentOwner != address(this)) {
            revert NameNotOwned(label, currentOwner);
        }

        // Set subregistry if provided
        if (address(subregistry) != address(0)) {
            ETH_REGISTRY.setSubregistry(state.tokenId, subregistry);
        }

        ETH_REGISTRY.setResolver(state.tokenId, resolver);

        // Transfer ownership to the new owner - all roles transfer with the token
        ETH_REGISTRY.safeTransferFrom(address(this), owner, state.tokenId, 1, "");

        emit NameClaimed(label, owner, address(subregistry), resolver);
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC1155 Receiver
    ////////////////////////////////////////////////////////////////////////

    function onERC1155Received(
        address /*operator*/,
        address /*from*/,
        uint256 /*id*/,
        uint256 /*value*/,
        bytes calldata /*data*/
    ) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(
        address /*operator*/,
        address /*from*/,
        uint256[] calldata /*ids*/,
        uint256[] calldata /*values*/,
        bytes calldata /*data*/
    ) external pure returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }
}
