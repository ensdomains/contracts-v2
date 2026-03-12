// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Roles for PermissionedResolver.
library PermissionedResolverLib {
    /// @dev Nybble 0 — authorizes setting address records. Root or name.
    uint256 internal constant ROLE_SET_ADDRESS = 1 << 0;
    uint256 internal constant ROLE_SET_ADDRESS_ADMIN = ROLE_SET_ADDRESS << 128;

    /// @dev Nybble 1 — authorizes setting text records. Root or name.
    uint256 internal constant ROLE_SET_TEXT = 1 << 4;
    uint256 internal constant ROLE_SET_TEXT_ADMIN = ROLE_SET_TEXT << 128;

    /// @dev Nybble 2 — authorizes setting the contenthash record. Root or name.
    uint256 internal constant ROLE_SET_CONTENTHASH = 1 << 8;
    uint256 internal constant ROLE_SET_CONTENTHASH_ADMIN = ROLE_SET_CONTENTHASH << 128;

    /// @dev Nybble 3 — authorizes setting the public key record. Root or name.
    uint256 internal constant ROLE_SET_PUBKEY = 1 << 12;
    uint256 internal constant ROLE_SET_PUBKEY_ADMIN = ROLE_SET_PUBKEY << 128;

    /// @dev Nybble 4 — authorizes setting ABI records. Root or name.
    uint256 internal constant ROLE_SET_ABI = 1 << 16;
    uint256 internal constant ROLE_SET_ABI_ADMIN = ROLE_SET_ABI << 128;

    /// @dev Nybble 5 — authorizes setting interface implementer records. Root or name.
    uint256 internal constant ROLE_SET_INTERFACE = 1 << 20;
    uint256 internal constant ROLE_SET_INTERFACE_ADMIN = ROLE_SET_INTERFACE << 128;

    /// @dev Nybble 6 — authorizes setting the reverse name record. Root or name.
    uint256 internal constant ROLE_SET_NAME = 1 << 24;
    uint256 internal constant ROLE_SET_NAME_ADMIN = ROLE_SET_NAME << 128;

    /// @dev Nybble 7 — authorizes setting data records. Root or name.
    uint256 internal constant ROLE_SET_DATA = 1 << 28;
    uint256 internal constant ROLE_SET_DATA_ADMIN = ROLE_SET_TEXT << 128;

    /// @dev Nybble 8 — authorizes linking records to names.  Root only.
    uint256 internal constant ROLE_RECORDS = 1 << 32;
    uint256 internal constant ROLE_RECORDS_ADMIN = ROLE_RECORDS << 128;

    /// @dev Nybble 31 — authorizes UUPS proxy upgrades. Root-only.
    uint256 internal constant ROLE_UPGRADE = 1 << 124;
    uint256 internal constant ROLE_UPGRADE_ADMIN = ROLE_UPGRADE << 128;

    bytes32 internal constant ANY_PART = 0;

    /// @dev Compute unique EAC resource ID.
    /// @param recordId The resource ID.
    /// @param part The part hash.
    /// @return The computed resource ID.
    function resource(uint256 recordId, bytes32 part) internal pure returns (uint256) {
        return uint256(keccak256(abi.encodePacked(bytes2(0x1900), recordId, part)));
    }

    /// @dev Compute `part` from `string` key.
    function partHash(string memory s) internal pure returns (bytes32) {
        return keccak256(bytes(s));
    }

    /// @dev Compute `part` from `uint256` key.
    function partHash(uint256 x) internal pure returns (bytes32 ret) {
        assembly {
            mstore(0, x)
            ret := keccak256(0, 32)
        }
    }
}
