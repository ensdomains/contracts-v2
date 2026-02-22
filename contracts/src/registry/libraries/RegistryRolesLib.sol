// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

library RegistryRolesLib {
    uint256 internal constant ROLE_REGISTRAR = 1 << 0;
    uint256 internal constant ROLE_REGISTRAR_ADMIN = ROLE_REGISTRAR << 128;

    uint256 internal constant ROLE_RENEW = 1 << 4;
    uint256 internal constant ROLE_RENEW_ADMIN = ROLE_RENEW << 128;

    uint256 internal constant ROLE_SET_SUBREGISTRY = 1 << 8;
    uint256 internal constant ROLE_SET_SUBREGISTRY_ADMIN = ROLE_SET_SUBREGISTRY << 128;

    uint256 internal constant ROLE_SET_RESOLVER = 1 << 12;
    uint256 internal constant ROLE_SET_RESOLVER_ADMIN = ROLE_SET_RESOLVER << 128;

    uint256 internal constant ROLE_CAN_TRANSFER_ADMIN = (1 << 16) << 128;

    uint256 internal constant ROLE_RESERVE = 1 << 20;
    uint256 internal constant ROLE_RESERVE_ADMIN = ROLE_RESERVE << 128;

    uint256 internal constant ROLE_UNREGISTER = 1 << 24;
    uint256 internal constant ROLE_UNREGISTER_ADMIN = ROLE_UNREGISTER << 128;

    uint256 internal constant ROLE_UPGRADE = 1 << 124;
    uint256 internal constant ROLE_UPGRADE_ADMIN = ROLE_UPGRADE << 128;
}
