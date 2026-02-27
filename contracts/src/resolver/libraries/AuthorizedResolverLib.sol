// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Roles and resource helpers for `AuthorizedResolver`.
library AuthorizedResolverLib {
    uint256 internal constant ROLE_SET_ADDR = 1 << 0;
    uint256 internal constant ROLE_SET_ADDR_ADMIN = ROLE_SET_ADDR << 128;

    uint256 internal constant ROLE_SET_TEXT = 1 << 4;
    uint256 internal constant ROLE_SET_TEXT_ADMIN = ROLE_SET_TEXT << 128;

    uint256 internal constant ROLE_SET_CONTENTHASH = 1 << 8;
    uint256 internal constant ROLE_SET_CONTENTHASH_ADMIN = ROLE_SET_CONTENTHASH << 128;

    uint256 internal constant ROLE_SET_PUBKEY = 1 << 12;
    uint256 internal constant ROLE_SET_PUBKEY_ADMIN = ROLE_SET_PUBKEY << 128;

    uint256 internal constant ROLE_SET_ABI = 1 << 16;
    uint256 internal constant ROLE_SET_ABI_ADMIN = ROLE_SET_ABI << 128;

    uint256 internal constant ROLE_SET_INTERFACE = 1 << 20;
    uint256 internal constant ROLE_SET_INTERFACE_ADMIN = ROLE_SET_INTERFACE << 128;

    uint256 internal constant ROLE_SET_NAME = 1 << 24;
    uint256 internal constant ROLE_SET_NAME_ADMIN = ROLE_SET_NAME << 128;

    uint256 internal constant ROLE_CLEAR = 1 << 28;
    uint256 internal constant ROLE_CLEAR_ADMIN = ROLE_CLEAR << 128;

    uint256 internal constant ROLE_AUTHORITY = 1 << 32;
    uint256 internal constant ROLE_AUTHORITY_ADMIN = ROLE_UPGRADE << 32;

    uint256 internal constant ROLE_UPGRADE = 1 << 124;
    uint256 internal constant ROLE_UPGRADE_ADMIN = ROLE_UPGRADE << 128;

    function addr(uint256 coinType) internal pure returns (bytes32 part) {
        assembly {
            mstore8(0, 1)
            mstore(1, coinType)
            part := keccak256(0, 33)
        }
    }

    function text(string memory key) internal pure returns (bytes32 part) {
        assembly {
            mstore8(0, 2)
            mstore(1, keccak256(add(key, 32), mload(key)))
            part := keccak256(0, 33)
        }
    }
}
