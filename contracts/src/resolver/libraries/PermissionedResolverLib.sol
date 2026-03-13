// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Roles for PermissionedResolver.
library PermissionedResolverLib {
    uint256 internal constant ROLE_SET_ADDR = 1 << 0;
    uint256 internal constant ROLE_SET_ADDR_ADMIN = ROLE_SET_ADDR << 128;

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

    /// @dev Nybble 7 — authorizes setting alias targets for name rewriting. Root-only.
    uint256 internal constant ROLE_SET_ALIAS = 1 << 28;
    uint256 internal constant ROLE_SET_ALIAS_ADMIN = ROLE_SET_ALIAS << 128;

    /// @dev Nybble 8 — authorizes clearing (version-bumping) all records for a node. Root or name.
    uint256 internal constant ROLE_CLEAR = 1 << 32;
    uint256 internal constant ROLE_CLEAR_ADMIN = ROLE_CLEAR << 128;

    /// @dev Nybble 31 — authorizes UUPS proxy upgrades. Root-only.
    uint256 internal constant ROLE_UPGRADE = 1 << 124;
    uint256 internal constant ROLE_UPGRADE_ADMIN = ROLE_UPGRADE << 128;

    /// @dev Computes `keccak256(node, part)` to create a unique EAC resource ID scoped to both
    ///      a name and a record type. Enables fine-grained per-record permissions.
    /// @param node The ENS namehash of the name.
    /// @param part The record-type identifier (e.g. from `addrPart` or `textPart`).
    /// @return ret The computed resource ID.
    function resource(bytes32 node, bytes32 part) internal pure returns (uint256 ret) {
        assembly {
            mstore(0, node)
            mstore(32, part)
            ret := keccak256(0, 64)
        }
        // Equivalent: return uint256(keccak256(abi.encode(node, part)));
    }

    /// @dev Computes a record-type identifier for address records, namespaced by coin type.
    /// @param coinType The SLIP-44 coin type.
    /// @return part The computed record-type identifier.
    function addrPart(uint256 coinType) internal pure returns (bytes32 part) {
        assembly {
            mstore8(0, 1)
            mstore(1, coinType)
            part := keccak256(0, 33)
        }
        // Equivalent: return keccak256(abi.encodePacked(uint8(1), coinType));
    }

    /// @dev Computes a record-type identifier for text records, namespaced by key.
    /// @param key The text record key.
    /// @return part The computed record-type identifier.
    function textPart(string memory key) internal pure returns (bytes32 part) {
        assembly {
            mstore8(0, 2)
            mstore(1, keccak256(add(key, 32), mload(key)))
            part := keccak256(0, 33)
        }
        // Equivalent: return keccak256(abi.encodePacked(uint8(2), key));
    }
}
