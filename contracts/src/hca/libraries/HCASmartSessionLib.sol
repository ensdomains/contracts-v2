// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title HCA Smart Session Library
/// @notice Reconstructs the authorization hashes used by Rhinestone Smart Sessions.
/// @dev Shares the Smart Session hashing rules used by the HCA validators.
library HCASmartSessionLib {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Canonical Smart Session emissary.
    address private constant SMART_SESSION_EMISSARY = 0xad568B3F825A8d5FFc06DD3253526B64D810Ae89;

    /// @dev Canonical one-of-one session validator.
    address private constant OWNABLE_SESSION_VALIDATOR = 0x000000000013fdB5234E4E3162a810F54d9f7E98;

    /// @dev Smart Session EIP-712 domain type hash.
    bytes32 private constant SMART_SESSION_DOMAIN_TYPEHASH =
        0xb03948446334eb9b2196d5eb166f69b9d49403eb4a12f36de8d3f9f3cb8e15c3;

    /// @dev Smart Session EIP-712 name hash.
    bytes32 private constant SMART_SESSION_NAME_HASH =
        0x909aaff4c04d02fd420ef163a6d750c002b0a00dc41a031ba039e3fdb4732133;

    /// @dev Smart Session EIP-712 version hash.
    bytes32 private constant SMART_SESSION_VERSION_HASH =
        0xc89efdaa54c0f20c7adf612882df0950f5a951637e0307cdcb4c672f298b8bc6;

    /// @dev Signed-session type hash.
    bytes32 private constant SIGNED_SESSION_TYPEHASH =
        0x984917e689987af96289e12c5f5e934fcdf1df4186108f69ff7e8c3df950ce33;

    /// @dev Chain-session type hash.
    bytes32 private constant CHAIN_SESSION_TYPEHASH =
        0xabc350ff4773ba356e85e2d2ee58d7d7511767acdb108b59058f5b4a5afc074b;

    /// @dev Multi-chain session type hash.
    bytes32 private constant MULTI_CHAIN_SESSION_TYPEHASH =
        0xb4323194e4ca3723804b96dc7a0960bde1afff2b080b8b288fdc264c82e21357;

    /// @dev Hash of the default empty Smart Session permissions.
    bytes32 private constant DEFAULT_SIGNED_PERMISSIONS_HASH =
        0x242b79d1322c5e6b12b617584cc2d5766cf18be6feb6acfa469ccf289e11e504;

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Derives the hashes that bind a one-of-one key to an account and policy.
    /// @dev Matches the permission and session hashing used by Rhinestone Smart Sessions.
    /// @param account The account authorized on the selected chain.
    /// @param sessionKey The session key installed in the Ownable validator.
    /// @param salt The application policy bound into the Smart Session.
    /// @return permissionId The standard Smart Session permission identifier.
    /// @return sessionDigest The signed-session struct hash for the selected chain.
    function authorizationHashes(address account, address sessionKey, bytes32 salt)
        internal
        pure
        returns (bytes32 permissionId, bytes32 sessionDigest)
    {
        bytes memory validatorInitData = _validatorInitData(sessionKey);
        permissionId = keccak256(abi.encode(OWNABLE_SESSION_VALIDATOR, validatorInitData, salt));
        sessionDigest = keccak256(
            abi.encode(
                SIGNED_SESSION_TYPEHASH,
                account,
                type(uint256).max,
                uint256(0),
                DEFAULT_SIGNED_PERMISSIONS_HASH,
                salt,
                OWNABLE_SESSION_VALIDATOR,
                keccak256(validatorInitData),
                SMART_SESSION_EMISSARY
            )
        );
    }

    /// @notice Hashes a chain identifier and its signed-session digest.
    /// @dev Produces one item in the ordered multi-chain authorization array.
    /// @param chainId The chain containing the authorized account.
    /// @param signedSessionHash The signed-session struct hash for the chain.
    /// @return result The chain-session struct hash.
    function chainSessionHash(uint64 chainId, bytes32 signedSessionHash)
        internal
        pure
        returns (bytes32 result)
    {
        return keccak256(abi.encode(CHAIN_SESSION_TYPEHASH, chainId, signedSessionHash));
    }

    /// @notice Produces the owner-signature digest for a multi-chain session authorization.
    /// @dev Applies the Smart Session EIP-712 domain to the ordered chain-session hash.
    /// @param chainSessionHashes The ordered chain-session struct hashes.
    /// @return result The Smart Session EIP-712 digest.
    function multiChainDigest(bytes32[] memory chainSessionHashes)
        internal
        pure
        returns (bytes32 result)
    {
        bytes32 structHash =
            keccak256(
                abi.encode(
                    MULTI_CHAIN_SESSION_TYPEHASH,
                    keccak256(abi.encodePacked(chainSessionHashes))
                )
            );
        bytes32 domainSeparator =
            keccak256(
                abi.encode(
                    SMART_SESSION_DOMAIN_TYPEHASH,
                    SMART_SESSION_NAME_HASH,
                    SMART_SESSION_VERSION_HASH
                )
            );
        return MessageHashUtils.toTypedDataHash(domainSeparator, structHash);
    }

    /// @dev Returns the standard one-of-one Ownable validator initialization data.
    function _validatorInitData(address sessionKey) private pure returns (bytes memory) {
        address[] memory owners = new address[](1);
        owners[0] = sessionKey;
        return abi.encode(uint256(1), owners);
    }
}
