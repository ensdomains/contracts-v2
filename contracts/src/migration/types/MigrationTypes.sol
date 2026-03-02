// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev The data for v1 to v2 transfers of a name.
struct TransferData {
    bytes dnsEncodedName;
    address owner;
    address subregistry;
    address resolver;
    uint256 roleBitmap;
    uint64 expires;
}

/// @dev The data for v1 to v2 migrations of names.
struct MigrationData {
    TransferData transferData;
    /**
     * @dev (Optional) Salt for CREATE2 deployments.
     */
    uint256 salt;
}
