// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    INameWrapper,
    CANNOT_UNWRAP,
    CANNOT_BURN_FUSES,
    CANNOT_TRANSFER,
    CANNOT_SET_RESOLVER,
    CANNOT_SET_TTL,
    CANNOT_CREATE_SUBDOMAIN,
    IS_DOT_ETH,
    CAN_EXTEND_EXPIRY,
    PARENT_CANNOT_CONTROL
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {
    IMigratedWrappedNameRegistry
} from "../../registry/interfaces/IMigratedWrappedNameRegistry.sol";
import {RegistryRolesLib} from "../../registry/libraries/RegistryRolesLib.sol";

/// @title LockedNamesLib
/// @notice Library for common locked name migration operations
/// @dev Contains shared logic for migrating locked names from ENS NameWrapper to v2 registries
library LockedNamesLib {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The fuses to burn during migration to prevent further changes
    /// @dev Includes all transferable and modifiable fuses including the lock fuse
    uint32 public constant FUSES_TO_BURN =
        CANNOT_UNWRAP |
            CANNOT_BURN_FUSES |
            CANNOT_TRANSFER |
            CANNOT_SET_RESOLVER |
            CANNOT_SET_TTL |
            CANNOT_CREATE_SUBDOMAIN;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0x1bfe8f0a`
    error NameNotLocked(uint256 tokenId);

    /// @dev Error selector: `0xf7d2a5a8`
    error NameNotEmancipated(uint256 tokenId);

    /// @dev Error selector: `0xaa289832`
    error NotDotEthName(uint256 tokenId);

    ////////////////////////////////////////////////////////////////////////
    // Library Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Deploys a new MigratedWrappedNameRegistry via VerifiableFactory
    /// @dev The owner will have the specified roles on the deployed registry
    /// @param factory The VerifiableFactory to use for deployment
    /// @param implementation The implementation address for the proxy
    /// @param owner The address that will own the deployed registry
    /// @param ownerRoles The roles to grant to the owner
    /// @param salt The salt for CREATE2 deployment
    /// @param parentDnsEncodedName The DNS-encoded name of the parent domain
    /// @return subregistry The address of the deployed registry
    function deployMigratedRegistry(
        VerifiableFactory factory,
        address implementation,
        address owner,
        uint256 ownerRoles,
        uint256 salt,
        bytes memory parentDnsEncodedName
    ) internal returns (address subregistry) {
        bytes memory initData = abi.encodeCall(
            IMigratedWrappedNameRegistry.initialize,
            (parentDnsEncodedName, owner, ownerRoles, address(0))
        );
        subregistry = factory.deployProxy(implementation, salt, initData);
    }

    /// @notice Freezes a name by clearing its resolver if possible and burning all migration fuses
    /// @dev Sets resolver to address(0) if CANNOT_SET_RESOLVER is not burned, then permanently freezes the name
    /// @param nameWrapper The NameWrapper contract
    /// @param tokenId The token ID to freeze
    /// @param fuses The current fuses on the name
    function freezeName(INameWrapper nameWrapper, uint256 tokenId, uint32 fuses) internal {
        // Clear resolver if CANNOT_SET_RESOLVER fuse is not set
        if ((fuses & CANNOT_SET_RESOLVER) == 0) {
            nameWrapper.setResolver(bytes32(tokenId), address(0));
        }

        // Burn all migration fuses
        nameWrapper.setFuses(bytes32(tokenId), uint16(FUSES_TO_BURN));
    }

    /// @notice Validates that a name is properly locked for migration
    /// @dev Checks that CANNOT_UNWRAP is set
    /// @param fuses The current fuses on the name
    /// @param tokenId The token ID for error reporting
    function validateLockedName(uint32 fuses, uint256 tokenId) internal pure {
        if ((fuses & CANNOT_UNWRAP) == 0) {
            revert NameNotLocked(tokenId);
        }
    }

    /// @notice Validates that a name is properly emancipated for migration
    /// @dev Checks that PARENT_CANNOT_CONTROL is set (emancipated). Name may or may not be locked.
    /// @param fuses The current fuses on the name
    /// @param tokenId The token ID for error reporting
    function validateEmancipatedName(uint32 fuses, uint256 tokenId) internal pure {
        if ((fuses & PARENT_CANNOT_CONTROL) == 0) {
            revert NameNotEmancipated(tokenId);
        }
    }

    /// @notice Validates that a name is a .eth second-level domain
    /// @dev Checks the IS_DOT_ETH fuse, which is only valid for .eth 2LDs
    /// @param fuses The current fuses on the name
    /// @param tokenId The token ID for error reporting
    function validateIsDotEth2LD(uint32 fuses, uint256 tokenId) internal pure {
        if ((fuses & IS_DOT_ETH) == 0) {
            revert NotDotEthName(tokenId);
        }
    }

    /// @notice Generates role bitmaps based on fuses
    /// @dev Returns two bitmaps: tokenRoles for the name registration and subRegistryRoles for the registry owner
    /// @param fuses The current fuses on the name
    /// @return tokenRoles The role bitmap for the owner on their name in their parent registry.
    /// @return subRegistryRoles The role bitmap for the owner on their name's subregistry.
    function generateRoleBitmapsFromFuses(
        uint32 fuses
    ) internal pure returns (uint256 tokenRoles, uint256 subRegistryRoles) {
        // Check if fuses are permanently frozen
        bool fusesFrozen = (fuses & CANNOT_BURN_FUSES) != 0;

        // Include renewal permissions if expiry can be extended
        if ((fuses & CAN_EXTEND_EXPIRY) != 0) {
            tokenRoles |= RegistryRolesLib.ROLE_RENEW;
            if (!fusesFrozen) {
                tokenRoles |= RegistryRolesLib.ROLE_RENEW_ADMIN;
            }
        }

        // Conditionally add resolver roles
        if ((fuses & CANNOT_SET_RESOLVER) == 0) {
            tokenRoles |= RegistryRolesLib.ROLE_SET_RESOLVER;
            if (!fusesFrozen) {
                tokenRoles |= RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN;
            }
        }

        // Add transfer admin role if transfers are allowed
        if ((fuses & CANNOT_TRANSFER) == 0) {
            tokenRoles |= RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        }

        // Owner gets registrar permissions on subregistry only if subdomain creation is allowed
        if ((fuses & CANNOT_CREATE_SUBDOMAIN) == 0) {
            subRegistryRoles |= RegistryRolesLib.ROLE_REGISTRAR;
            if (!fusesFrozen) {
                subRegistryRoles |= RegistryRolesLib.ROLE_REGISTRAR_ADMIN;
            }
        }

        // Add renewal roles to subregistry
        subRegistryRoles |= RegistryRolesLib.ROLE_RENEW;
        subRegistryRoles |= RegistryRolesLib.ROLE_RENEW_ADMIN;
    }
}
