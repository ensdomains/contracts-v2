// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Defines the registry-specific roles used by `PermissionedRegistry` within the
///      `EnhancedAccessControl` nybble-packed bitmap system. Each role occupies one nybble (4 bits)
///      at a specific index, with its admin counterpart shifted 128 bits higher.
library RegistryRolesLib {
    // root only
    uint256 internal constant ROLE_REGISTRAR = 1 << 0;
    /// @dev Grants authority to assign/revoke the registrar role.
    uint256 internal constant ROLE_REGISTRAR_ADMIN = ROLE_REGISTRAR << 128;

    // root only
    uint256 internal constant ROLE_REGISTER_RESERVED = 1 << 4;
    /// @dev Grants authority to assign/revoke the register-reserved role.
    uint256 internal constant ROLE_REGISTER_RESERVED_ADMIN = ROLE_REGISTER_RESERVED << 128;

    // root only
    uint256 internal constant ROLE_SET_PARENT = 1 << 8;
    uint256 internal constant ROLE_SET_PARENT_ADMIN = ROLE_SET_PARENT << 128;

    // root or token
    uint256 internal constant ROLE_UNREGISTER = 1 << 12;
    /// @dev Grants authority to assign/revoke the unregister role.
    uint256 internal constant ROLE_UNREGISTER_ADMIN = ROLE_UNREGISTER << 128;

    // root or token
    uint256 internal constant ROLE_RENEW = 1 << 16;
    uint256 internal constant ROLE_RENEW_ADMIN = ROLE_RENEW << 128;

    // root or token
    uint256 internal constant ROLE_SET_SUBREGISTRY = 1 << 20;
    uint256 internal constant ROLE_SET_SUBREGISTRY_ADMIN = ROLE_SET_SUBREGISTRY << 128;

    // root or token
    uint256 internal constant ROLE_SET_RESOLVER = 1 << 24;
    uint256 internal constant ROLE_SET_RESOLVER_ADMIN = ROLE_SET_RESOLVER << 128;

    // token only
    uint256 internal constant ROLE_CAN_TRANSFER_ADMIN = (1 << 28) << 128;

    // root only
    uint256 internal constant ROLE_UPGRADE = 1 << 124;
    /// @dev Grants authority to assign/revoke the upgrade role.
    uint256 internal constant ROLE_UPGRADE_ADMIN = ROLE_UPGRADE << 128;
}
