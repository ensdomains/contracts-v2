// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Defines the registry-specific roles used by `PermissionedRegistry` within the
///      `EnhancedAccessControl` nybble-packed bitmap system. Each role occupies one nybble (4 bits)
///      at a specific index, with its admin counterpart shifted 128 bits higher.
library RegistryRolesLib {
    /// @dev Nybble 0: authorizes registering and reserving new names. Root only.
    uint256 internal constant ROLE_REGISTRAR = 1 << (0 << 2);
    /// @dev Nybble 32: authorizes setting `ROLE_REGISTRAR`.
    uint256 internal constant ROLE_REGISTRAR_ADMIN = ROLE_REGISTRAR << 128;

    /// @dev Nybble 1: authorizes registering a reserved name (promoting it from RESERVED to REGISTERED). Root-only.
    uint256 internal constant ROLE_REGISTER_RESERVED = 1 << (1 << 2);
    /// @dev Nybble 33: authorizes setting `ROLE_REGISTER_RESERVED`.
    uint256 internal constant ROLE_REGISTER_RESERVED_ADMIN = ROLE_REGISTER_RESERVED << 128;

    /// @dev Nybble 2: authorizes setting the parent registry. Root-only.
    uint256 internal constant ROLE_SET_PARENT = 1 << (2 << 2);
    /// @dev Nybble 34: authorizes setting `ROLE_SET_PARENT`.
    uint256 internal constant ROLE_SET_PARENT_ADMIN = ROLE_SET_PARENT << 128;

    /// @dev Nybble 3: authorizes unregistering names. Root or token.
    uint256 internal constant ROLE_UNREGISTER = 1 << (3 << 2);
    /// @dev Nybble 35: authorizes setting `ROLE_UNREGISTER`.
    uint256 internal constant ROLE_UNREGISTER_ADMIN = ROLE_UNREGISTER << 128;

    /// @dev Nybble 4: authorizes extending name expiry. Root-only.
    uint256 internal constant ROLE_RENEW = 1 << (4 << 2);
    /// @dev Nybble 36: authorizes setting `ROLE_RENEW`.
    uint256 internal constant ROLE_RENEW_ADMIN = ROLE_RENEW << 128;

    /// @dev Nybble 5: authorizes changing a name's child registry. Root or token.
    uint256 internal constant ROLE_SET_SUBREGISTRY = 1 << (5 << 2);
    /// @dev Nybble 37: authorizes setting `ROLE_SET_SUBREGISTRY`.
    uint256 internal constant ROLE_SET_SUBREGISTRY_ADMIN = ROLE_SET_SUBREGISTRY << 128;

    /// @dev Nybble 6: authorizes changing a name's resolver. Root or token.
    uint256 internal constant ROLE_SET_RESOLVER = 1 << (6 << 2);
    /// @dev Nybble 38: authorizes setting `ROLE_SET_RESOLVER`.
    uint256 internal constant ROLE_SET_RESOLVER_ADMIN = ROLE_SET_RESOLVER << 128;

    /// @dev Nybble 7: marks a registry for transfer.
    ///      This role is only checked on the child registry.
    uint256 internal constant ROLE_CAN_TRANSFER = 1 << (7 << 2);
    /// @dev Nybble 39: authorizes ERC1155 token transfers.
    ///      This role is only checked on the token owner, not the operator.
    uint256 internal constant ROLE_CAN_TRANSFER_ADMIN = ROLE_CAN_TRANSFER << 128;

    /// @dev Nybble 8: tags a name that was registered via `ROLE_REGISTER_RESERVED`. Token only. Not revokable.
    uint256 internal constant ROLE_WAS_RESERVED = (1 << (8 << 2));

    /// @dev Nybble 9: authorizes setting the URI. Root-only.
    uint256 internal constant ROLE_SET_URI = 1 << (9 << 2);
    /// @dev Nybble 41: authorizes setting `ROLE_SET_URI`.
    uint256 internal constant ROLE_SET_URI_ADMIN = ROLE_SET_URI << 128;

    /// @dev Nybble 10: if absent on token, token is emancipated.
    uint256 internal constant ROLE_PARENT_CONTROL = (1 << (10 << 2));
    /// @dev Nybble 42: authorizes setting ROLE_PARENT_CONTROL.
    uint256 internal constant ROLE_PARENT_CONTROL_ADMIN = ROLE_PARENT_CONTROL << 128;

    /// @dev Nybble 43: if present on root, allows upgrades to any implementation.
    uint256 internal constant ROLE_UPGRADE_ANY_ADMIN = 1 << (43 << 2);

    /// @dev Nybble 30: authorizes contract naming. Root-only.
    uint256 internal constant ROLE_CAN_NAME = 1 << (30 << 2);
    /// @dev Nybble 62: authorizes setting ROLE_CAN_NAME.
    uint256 internal constant ROLE_CAN_NAME_ADMIN = ROLE_CAN_NAME << 128;

    /// @dev Nybble 31: authorizes UUPS proxy upgrades. Root-only.
    uint256 internal constant ROLE_UPGRADE = 1 << (31 << 2);
    /// @dev Nybble 63: authorizes setting `ROLE_UPGRADE`.
    uint256 internal constant ROLE_UPGRADE_ADMIN = ROLE_UPGRADE << 128;

    /// @dev Roles that safe transfers must revoke from non-owners.
    uint256 internal constant TOKEN_EMANCIPATION_ROLE_BITMAP =
        ROLE_SET_SUBREGISTRY | ROLE_SET_RESOLVER | ROLE_UNREGISTER;

    /// @dev Roles that should cause token regeneration.
    uint256 internal constant REGENERATION_ROLE_BITMAP =
        ROLE_PARENT_CONTROL |
        ROLE_PARENT_CONTROL_ADMIN |
        ROLE_CAN_TRANSFER |
        ROLE_CAN_TRANSFER_ADMIN |
        TOKEN_EMANCIPATION_ROLE_BITMAP |
        TOKEN_EMANCIPATION_ROLE_BITMAP << 128;
}
