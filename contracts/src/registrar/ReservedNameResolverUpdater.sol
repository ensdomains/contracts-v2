// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";
import {LibLabel} from "../utils/LibLabel.sol";

/// @title ReservedNameResolverUpdater
/// @notice Points reserved names of a registry at one resolver, each name in a single call.
///
/// A reserved name has no owner and so no roles, and a registry lets no account set resolvers
/// registry-wide, so a reservation's resolver cannot be changed in place. This contract moves it
/// instead, in one transaction: it registers the reservation to itself with only the role to
/// unregister it, unregisters it, and reserves it again with the resolver, the same subregistry
/// and the same expiry. The name is never left unreserved between transactions, and unregistering
/// bumps its resource, so the role taken in the first step does not outlive the call.
///
/// It needs the registry's root `ROLE_REGISTRAR` and `ROLE_REGISTER_RESERVED` while it works, and
/// only its owner can call it. Once those roles are revoked it can do nothing.
///
contract ReservedNameResolverUpdater is Ownable, ERC165, IERC1155Receiver {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The registry whose reserved names are moved.
    IPermissionedRegistry public immutable REGISTRY;

    /// @notice The resolver every moved name is reserved with.
    address public immutable RESOLVER;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when a name to move is not reserved.
    /// @dev Error selector: `0xd17ee357`
    /// @param label The label that is not reserved.
    error NameNotReserved(string label);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param registry The registry whose reserved names are moved.
    /// @param resolver The resolver every moved name is reserved with.
    /// @param owner_ The only account that may move names.
    constructor(IPermissionedRegistry registry, address resolver, address owner_) Ownable(owner_) {
        REGISTRY = registry;
        RESOLVER = resolver;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(ERC165, IERC165)
        returns (bool)
    {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Reserves each name in `labels` again with the resolver, keeping its subregistry
    ///         and expiry. A name already reserved with the resolver is left alone.
    /// @dev Reverts `NameNotReserved` for a name that is available or registered, so the whole
    ///      batch either moves or changes nothing.
    /// @param labels The labels of the reserved names to move.
    function updateResolvers(string[] calldata labels) external onlyOwner {
        for (uint256 i; i < labels.length; ++i) {
            string calldata label = labels[i];
            IPermissionedRegistry.State memory state = REGISTRY.getState(LibLabel.id(label));
            if (state.status != IPermissionedRegistry.Status.RESERVED) {
                revert NameNotReserved(label);
            }
            if (REGISTRY.getResolver(label) == RESOLVER) {
                continue;
            }
            IRegistry subregistry = REGISTRY.getSubregistry(label);
            uint256 tokenId =
                REGISTRY.register(
                    label,
                    address(this),
                    IRegistry(address(0)),
                    address(0),
                    RegistryRolesLib.ROLE_UNREGISTER,
                    0
                );
            REGISTRY.unregister(tokenId);
            REGISTRY.register(label, address(0), subregistry, RESOLVER, 0, state.expiry);
        }
    }

    /// @inheritdoc IERC1155Receiver
    /// @notice Accepts a name's token from the registry for the moment the name is registered
    ///         to this contract.
    /// @dev Reverts `UnauthorizedCaller` for a token from any other contract.
    function onERC1155Received(
        address /*operator*/,
        address /*from*/,
        uint256 /*id*/,
        uint256 /*value*/,
        bytes calldata /*data*/
    )
        external
        view
        returns (bytes4)
    {
        if (msg.sender != address(REGISTRY)) {
            revert UnauthorizedCaller(msg.sender);
        }
        return this.onERC1155Received.selector;
    }

    /// @inheritdoc IERC1155Receiver
    /// @notice Refuses batch transfers, which moving a name never makes.
    /// @dev Always reverts `UnauthorizedCaller`.
    function onERC1155BatchReceived(
        address /*operator*/,
        address /*from*/,
        uint256[] calldata /*ids*/,
        uint256[] calldata /*values*/,
        bytes calldata /*data*/
    )
        external
        view
        returns (bytes4)
    {
        revert UnauthorizedCaller(msg.sender);
    }
}
