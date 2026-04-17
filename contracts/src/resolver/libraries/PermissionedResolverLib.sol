// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Roles for PermissionedResolver.
library PermissionedResolverLib {
    /// @dev Nybble 0: authorizes setting address records. Root or name.
    uint256 internal constant ROLE_SET_ADDRESS = 1 << 0;
    /// @dev Nybble 32: authorizes setting ROLE_SET_ADDRESS.
    uint256 internal constant ROLE_SET_ADDRESS_ADMIN = ROLE_SET_ADDRESS << 128;

    /// @dev Nybble 1: authorizes setting text records. Root or name.
    uint256 internal constant ROLE_SET_TEXT = 1 << 4;
    /// @dev Nybble 33: authorizes setting ROLE_SET_TEXT.
    uint256 internal constant ROLE_SET_TEXT_ADMIN = ROLE_SET_TEXT << 128;

    /// @dev Nybble 2: authorizes setting the contenthash record. Root or name.
    uint256 internal constant ROLE_SET_CONTENTHASH = 1 << 8;
    /// @dev Nybble 34: authorizes setting ROLE_SET_CONTENTHASH.
    uint256 internal constant ROLE_SET_CONTENTHASH_ADMIN = ROLE_SET_CONTENTHASH << 128;

    /// @dev Nybble 3: authorizes setting the public key record. Root or name.
    uint256 internal constant ROLE_SET_PUBKEY = 1 << 12;
    /// @dev Nybble 35: authorizes setting ROLE_SET_PUBKEY.
    uint256 internal constant ROLE_SET_PUBKEY_ADMIN = ROLE_SET_PUBKEY << 128;

    /// @dev Nybble 4: authorizes setting ABI records. Root or name.
    uint256 internal constant ROLE_SET_ABI = 1 << 16;
    /// @dev Nybble 36: authorizes setting ROLE_SET_ABI.
    uint256 internal constant ROLE_SET_ABI_ADMIN = ROLE_SET_ABI << 128;

    /// @dev Nybble 5: authorizes setting interface implementer records. Root or name.
    uint256 internal constant ROLE_SET_INTERFACE = 1 << 20;
    /// @dev Nybble 37: authorizes setting ROLE_SET_INTERFACE.
    uint256 internal constant ROLE_SET_INTERFACE_ADMIN = ROLE_SET_INTERFACE << 128;

    /// @dev Nybble 6: authorizes setting the reverse name record. Root or name.
    uint256 internal constant ROLE_SET_NAME = 1 << 24;
    /// @dev Nybble 38: authorizes setting ROLE_SET_NAME.
    uint256 internal constant ROLE_SET_NAME_ADMIN = ROLE_SET_NAME << 128;

    /// @dev Nybble 7: authorizes setting data records. Root or name.
    uint256 internal constant ROLE_SET_DATA = 1 << 28;
    /// @dev Nybble 39: authorizes setting ROLE_SET_DATA.
    uint256 internal constant ROLE_SET_DATA_ADMIN = ROLE_SET_TEXT << 128;

    /// @dev Nybble 8: authorizes creating records.  Root only.
    uint256 internal constant ROLE_NEW_RECORD = 1 << 32;
    /// @dev Nybble 40: authorizes setting ROLE_NEW_RECORD.
    uint256 internal constant ROLE_NEW_RECORD_ADMIN = ROLE_NEW_RECORD << 128;

    /// @dev Nybble 9: authorizes creating records.  Root only.
    uint256 internal constant ROLE_LINK_RECORD = 1 << 36;
    /// @dev Nybble 41: authorizes setting ROLE_LINK_RECORD.
    uint256 internal constant ROLE_LINK_RECORD_ADMIN = ROLE_LINK_RECORD << 128;

    /// @dev Nybble 10: authorizes clearing records.  Root only.
    uint256 internal constant ROLE_CLEAR_RECORD = 1 << 40;
    /// @dev Nybble 42: authorizes setting ROLE_CLEAR_RECORD.
    uint256 internal constant ROLE_CLEAR_RECORD_ADMIN = ROLE_CLEAR_RECORD << 128;

    /// @dev Nybble 31: authorizes UUPS proxy upgrades. Root-only.
    uint256 internal constant ROLE_UPGRADE = 1 << 124;
    /// @dev Nybble 63: authorizes setting ROLE_UPGRADE.
    uint256 internal constant ROLE_UPGRADE_ADMIN = ROLE_UPGRADE << 128;

    /// @dev Generate generic record setter calldata.
    function anySetter(bytes memory name) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(bytes4(0), name);
    }

    /// @dev Compute unique EAC resource ID.
    /// @param recordId The resource ID.
    /// @param part The part hash.
    /// @return The computed resource ID.
    function resource(uint256 recordId, bytes32 part) internal pure returns (uint256) {
        if (recordId == 0 && part == bytes32(0)) {
            return 0;
        }
        return uint256(keccak256(abi.encodePacked(bytes2(0x1900), recordId, part)));
    }

    /// @dev Convience for resource with any part.
    function resource(uint256 recordId) internal pure returns (uint256) {
        return resource(recordId, bytes32(0));
    }

    /// @dev Compute `part` from `string` key.
    function partHash(string memory s) internal pure returns (bytes32) {
        return keccak256(bytes(s));
    }

    /// @dev Compute `part` from `uint256` key.
    function partHash(uint256 x) internal pure returns (bytes32 part) {
        assembly {
            mstore(0, x)
            part := keccak256(0, 32)
        }
    }

    /// @dev Compute `part` from `bytes4` key.
    function partHash(bytes4 x) internal pure returns (bytes32) {
        return partHash(uint32(x));
    }
}
