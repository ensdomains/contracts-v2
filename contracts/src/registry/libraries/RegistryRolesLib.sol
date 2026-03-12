// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Defines the registry-specific roles used by `PermissionedRegistry` within the
///      `EnhancedAccessControl` nybble-packed bitmap system. Each role occupies one nybble (4 bits)
///      at a specific index, with its admin counterpart shifted 128 bits higher.
library RegistryRolesLib {
    /// @dev Nybble 0 — authorizes registering and reserving new names. Root only.
    uint256 internal constant ROLE_REGISTRAR = 1 << 0;
    uint256 internal constant ROLE_REGISTRAR_ADMIN = ROLE_REGISTRAR << 128;

    /// @dev Nybble 1 — authorizes registering a reserved name (promoting it from RESERVED to REGISTERED). Root-only.
    uint256 internal constant ROLE_REGISTER_RESERVED = 1 << 4;
    uint256 internal constant ROLE_REGISTER_RESERVED_ADMIN = ROLE_REGISTER_RESERVED << 128;

    /// @dev Nybble 2 — authorizes setting the parent registry. Root-only.
    uint256 internal constant ROLE_SET_PARENT = 1 << 8;
    uint256 internal constant ROLE_SET_PARENT_ADMIN = ROLE_SET_PARENT << 128;

    /// @dev Nybble 3 — authorizes unregistering names. Root or token.
    uint256 internal constant ROLE_UNREGISTER = 1 << 12;
    uint256 internal constant ROLE_UNREGISTER_ADMIN = ROLE_UNREGISTER << 128;

    /// @dev Nybble 4 — authorizes extending name expiry. Root or token.
    uint256 internal constant ROLE_RENEW = 1 << 16;
    uint256 internal constant ROLE_RENEW_ADMIN = ROLE_RENEW << 128;

    /// @dev Nybble 5 — authorizes changing a name's child registry. Root or token.
    uint256 internal constant ROLE_SET_SUBREGISTRY = 1 << 20;
    uint256 internal constant ROLE_SET_SUBREGISTRY_ADMIN = ROLE_SET_SUBREGISTRY << 128;

    /// @dev Nybble 6 — authorizes changing a name's resolver. Root or token.
    uint256 internal constant ROLE_SET_RESOLVER = 1 << 24;
    uint256 internal constant ROLE_SET_RESOLVER_ADMIN = ROLE_SET_RESOLVER << 128;

    /// @dev Nybble 7 — authorizes ERC1155 token transfers. Root or token.
    ///      This role is only checked on the token owner, not the operator.
    uint256 internal constant ROLE_CAN_TRANSFER_ADMIN = (1 << 28) << 128;

    /// @dev Nybble 31 — authorizes UUPS proxy upgrades. Root-only.
    uint256 internal constant ROLE_UPGRADE = 1 << 124;
    uint256 internal constant ROLE_UPGRADE_ADMIN = ROLE_UPGRADE << 128;
}
