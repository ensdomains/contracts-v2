// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Defines the EIP-7201 namespaced storage layout and role constants for `OwnedResolver`.
///      The storage follows a versioned-records pattern: each ENS node has a version counter,
///      and records are stored per `(node, version)` pair, allowing bulk invalidation by
///      incrementing the version.
library OwnedResolverLib {
    /// @dev Top-level storage layout for `OwnedResolver`.
    /// @param aliases DNS-encoded alias target for internal name rewriting, keyed by node.
    /// @param versions Monotonically increasing version counter per node; incrementing
    ///        invalidates all existing records for the node.
    /// @param records The actual resolver records for the current version, keyed by
    ///        `(node, version)`.
    struct Storage {
        mapping(bytes32 node => bytes) aliases;
        mapping(bytes32 node => uint64) versions;
        mapping(bytes32 node => mapping(uint64 version => Record)) records;
    }

    /// @dev Holds all resolver record types for a single name version -- contenthash,
    ///      public key, reverse name, plus mappings for multi-chain addresses, text records,
    ///      ABIs, and interface implementations.
    struct Record {
        bytes contenthash;
        bytes32[2] pubkey;
        string name;
        mapping(uint256 coinType => bytes addressBytes) addresses;
        mapping(string key => string value) texts;
        mapping(uint256 contentType => bytes data) abis;
        mapping(bytes4 interfaceId => address implementer) interfaces;
    }

    /// @dev EIP-7201 storage slot derived from `keccak256("eth.ens.storage.OwnedResolver")`.
    ///      Used to locate the `Storage` struct in a proxy-safe way.
    uint256 internal constant NAMED_SLOT = uint256(keccak256("eth.ens.storage.OwnedResolver"));

    /// @dev Role granting permission to set multi-chain address records.
    uint256 internal constant ROLE_SET_ADDR = 1 << 0;
    /// @dev Admin variant of the address-setting role; allows delegating that permission.
    uint256 internal constant ROLE_SET_ADDR_ADMIN = ROLE_SET_ADDR << 128;

    /// @dev Role granting permission to set text records.
    uint256 internal constant ROLE_SET_TEXT = 1 << 4;
    /// @dev Admin variant of the text-setting role; allows delegating that permission.
    uint256 internal constant ROLE_SET_TEXT_ADMIN = ROLE_SET_TEXT << 128;

    /// @dev Role granting permission to set the contenthash record.
    uint256 internal constant ROLE_SET_CONTENTHASH = 1 << 8;
    /// @dev Admin variant of the contenthash-setting role; allows delegating that permission.
    uint256 internal constant ROLE_SET_CONTENTHASH_ADMIN = ROLE_SET_CONTENTHASH << 128;

    /// @dev Role granting permission to set the public key record.
    uint256 internal constant ROLE_SET_PUBKEY = 1 << 12;
    /// @dev Admin variant of the pubkey-setting role; allows delegating that permission.
    uint256 internal constant ROLE_SET_PUBKEY_ADMIN = ROLE_SET_PUBKEY << 128;

    /// @dev Role granting permission to set ABI records.
    uint256 internal constant ROLE_SET_ABI = 1 << 16;
    /// @dev Admin variant of the ABI-setting role; allows delegating that permission.
    uint256 internal constant ROLE_SET_ABI_ADMIN = ROLE_SET_ABI << 128;

    /// @dev Role granting permission to set interface implementer records.
    uint256 internal constant ROLE_SET_INTERFACE = 1 << 20;
    /// @dev Admin variant of the interface-setting role; allows delegating that permission.
    uint256 internal constant ROLE_SET_INTERFACE_ADMIN = ROLE_SET_INTERFACE << 128;

    /// @dev Role granting permission to set the reverse name record.
    uint256 internal constant ROLE_SET_NAME = 1 << 24;
    /// @dev Admin variant of the name-setting role; allows delegating that permission.
    uint256 internal constant ROLE_SET_NAME_ADMIN = ROLE_SET_NAME << 128;

    /// @dev Role granting permission to set alias targets for name rewriting.
    uint256 internal constant ROLE_SET_ALIAS = 1 << 28;
    /// @dev Admin variant of the alias-setting role; allows delegating that permission.
    uint256 internal constant ROLE_SET_ALIAS_ADMIN = ROLE_SET_ALIAS << 128;

    /// @dev Role granting permission to clear (version-bump) all records for a node.
    uint256 internal constant ROLE_CLEAR = 1 << 32;
    /// @dev Admin variant of the clear role; allows delegating that permission.
    uint256 internal constant ROLE_CLEAR_ADMIN = ROLE_CLEAR << 128;

    /// @dev Role granting permission to upgrade the resolver contract.
    uint256 internal constant ROLE_UPGRADE = 1 << 124;
    /// @dev Admin variant of the upgrade role; allows delegating that permission.
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
        //return uint256(keccak256(abi.encode(node, part)));
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
        //return keccak256(abi.encodePacked(uint8(1), coinType));
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
        //return keccak256(abi.encodePacked(uint8(2), key));
    }
}
