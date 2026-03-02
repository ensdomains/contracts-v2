// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Defines the registry-specific roles used by `PermissionedRegistry` within the
///      `EnhancedAccessControl` nybble-packed bitmap system. Each role occupies one nybble (4 bits)
///      at a specific index, with its admin counterpart shifted 128 bits higher.
library RegistryRolesLib {
    /// @dev Nybble 0 — authorizes registering new names.
    uint256 internal constant ROLE_REGISTRAR = 1 << 0;
    /// @dev Grants authority to assign/revoke the registrar role.
    uint256 internal constant ROLE_REGISTRAR_ADMIN = ROLE_REGISTRAR << 128;

    /// @dev Nybble 1 — authorizes registering a reserved name (promoting it from RESERVED to REGISTERED).
    uint256 internal constant ROLE_REGISTER_RESERVED = 1 << 4;
    /// @dev Grants authority to assign/revoke the register-reserved role.
    uint256 internal constant ROLE_REGISTER_RESERVED_ADMIN = ROLE_REGISTER_RESERVED << 128;

    /// @dev Nybble 2 — authorizes extending name expiry.
    uint256 internal constant ROLE_RENEW = 1 << 8;
    /// @dev Grants authority to assign/revoke the renew role.
    uint256 internal constant ROLE_RENEW_ADMIN = ROLE_RENEW << 128;

    /// @dev Nybble 3 — authorizes unregistering/deleting names.
    uint256 internal constant ROLE_UNREGISTER = 1 << 12;
    /// @dev Grants authority to assign/revoke the unregister role.
    uint256 internal constant ROLE_UNREGISTER_ADMIN = ROLE_UNREGISTER << 128;

    /// @dev Nybble 4 — authorizes changing a name's child registry.
    uint256 internal constant ROLE_SET_SUBREGISTRY = 1 << 16;
    /// @dev Grants authority to assign/revoke the set-subregistry role.
    uint256 internal constant ROLE_SET_SUBREGISTRY_ADMIN = ROLE_SET_SUBREGISTRY << 128;

    /// @dev Nybble 5 — authorizes changing a name's resolver.
    uint256 internal constant ROLE_SET_RESOLVER = 1 << 20;
    /// @dev Grants authority to assign/revoke the set-resolver role.
    uint256 internal constant ROLE_SET_RESOLVER_ADMIN = ROLE_SET_RESOLVER << 128;

    /// @dev Nybble 6, admin-only — authorizes ERC1155 token transfers. Has no regular counterpart;
    ///      only the admin bit is defined.
    uint256 internal constant ROLE_CAN_TRANSFER_ADMIN = (1 << 24) << 128;

    /// @dev Nybble 31 — authorizes UUPS proxy upgrades.
    uint256 internal constant ROLE_UPGRADE = 1 << 124;
    /// @dev Grants authority to assign/revoke the upgrade role.
    uint256 internal constant ROLE_UPGRADE_ADMIN = ROLE_UPGRADE << 128;
}
