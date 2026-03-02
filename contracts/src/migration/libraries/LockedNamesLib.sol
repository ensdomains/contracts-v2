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
/// @notice Library for migrating wrapped names from the ENS v1 NameWrapper to v2 registries.
/// @dev Provides validation, fuse-to-role translation, subregistry deployment, and name freezing
///      for the locked and emancipated name migration paths. See
///      https://docs.ens.domains/wrapper/fuses for NameWrapper fuse semantics.
library LockedNamesLib {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice Composite bitmask of owner-controlled fuses burned during migration to freeze the
    ///         name in the NameWrapper. After burning, the name cannot be unwrapped, transferred,
    ///         have its resolver or TTL changed, create new subdomains, or have additional fuses burned.
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

    /// @dev Thrown when a name required to be locked (i.e., `CANNOT_UNWRAP` burned) is not.
    /// @dev Error selector: `0x1bfe8f0a`
    error NameNotLocked(uint256 tokenId);

    /// @dev Thrown when a name required to be emancipated (i.e., `PARENT_CANNOT_CONTROL` burned) is not.
    /// @dev Error selector: `0xf7d2a5a8`
    error NameNotEmancipated(uint256 tokenId);

    /// @dev Thrown when a name is expected to be a .eth 2LD but the `IS_DOT_ETH` fuse is not present.
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
        // Clear resolver if CANNOT_SET_RESOLVER fuse has not been burned
        if ((fuses & CANNOT_SET_RESOLVER) == 0) {
            nameWrapper.setResolver(bytes32(tokenId), address(0));
        }

        // Burn all migration fuses
        nameWrapper.setFuses(bytes32(tokenId), uint16(FUSES_TO_BURN));
    }

    /// @notice Validates that a name is in the Locked state for migration.
    /// @dev A name is Locked when the owner-controlled fuse `CANNOT_UNWRAP` has been burned,
    ///      preventing it from being unwrapped from the NameWrapper.
    /// @param fuses The current fuses on the name
    /// @param tokenId The token ID for error reporting
    function validateLockedName(uint32 fuses, uint256 tokenId) internal pure {
        if ((fuses & CANNOT_UNWRAP) == 0) {
            revert NameNotLocked(tokenId);
        }
    }

    /// @notice Validates that a name is in the Emancipated state for migration.
    /// @dev A name is Emancipated when the parent-controlled fuse `PARENT_CANNOT_CONTROL` has been
    ///      burned, meaning the parent owner can no longer replace, delete, or burn additional fuses
    ///      on this name. The name may or may not also be Locked.
    /// @param fuses The current fuses on the name
    /// @param tokenId The token ID for error reporting
    function validateEmancipatedName(uint32 fuses, uint256 tokenId) internal pure {
        if ((fuses & PARENT_CANNOT_CONTROL) == 0) {
            revert NameNotEmancipated(tokenId);
        }
    }

    /// @notice Validates that a name is a .eth second-level domain.
    /// @dev The `IS_DOT_ETH` fuse is a parent-controlled fuse automatically set by the NameWrapper
    ///      when .eth 2LDs are wrapped. It cannot be manually burned and serves as a flag identifying
    ///      the name as a second-level .eth domain.
    /// @param fuses The current fuses on the name
    /// @param tokenId The token ID for error reporting
    function validateIsDotEth2LD(uint32 fuses, uint256 tokenId) internal pure {
        if ((fuses & IS_DOT_ETH) == 0) {
            revert NotDotEthName(tokenId);
        }
    }

    /// @notice Translates NameWrapper fuses into v2 role bitmaps for the migrated name.
    /// @dev Examines which owner-controlled and parent-controlled fuses have been burned to determine
    ///      what permissions the owner should retain in the v2 system. Fuses that revoke capabilities
    ///      (e.g., `CANNOT_SET_RESOLVER`) result in the corresponding v2 role being omitted. Admin
    ///      variants of roles are only granted when `CANNOT_BURN_FUSES` has not been burned, preserving
    ///      the ability to delegate permissions when fuse state is not yet frozen.
    /// @param fuses The current fuses on the name
    /// @return tokenRoles The role bitmap for the owner on their name in their parent registry.
    /// @return subRegistryRoles The role bitmap for the owner on their name's subregistry.
    function generateRoleBitmapsFromFuses(
        uint32 fuses
    ) internal pure returns (uint256 tokenRoles, uint256 subRegistryRoles) {
        // Check if `CANNOT_BURN_FUSES` (owner-controlled) has been burned, freezing the fuse configuration
        bool fusesFrozen = (fuses & CANNOT_BURN_FUSES) != 0;

        // Grant renewal role if the parent-controlled fuse `CAN_EXTEND_EXPIRY` has been burned
        if ((fuses & CAN_EXTEND_EXPIRY) != 0) {
            tokenRoles |= RegistryRolesLib.ROLE_RENEW;
            if (!fusesFrozen) {
                tokenRoles |= RegistryRolesLib.ROLE_RENEW_ADMIN;
            }
        }

        // Grant resolver role if the owner-controlled fuse `CANNOT_SET_RESOLVER` has NOT been burned
        if ((fuses & CANNOT_SET_RESOLVER) == 0) {
            tokenRoles |= RegistryRolesLib.ROLE_SET_RESOLVER;
            if (!fusesFrozen) {
                tokenRoles |= RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN;
            }
        }

        // Grant transfer role if the owner-controlled fuse `CANNOT_TRANSFER` has NOT been burned
        if ((fuses & CANNOT_TRANSFER) == 0) {
            tokenRoles |= RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        }

        // Grant registrar role on subregistry if `CANNOT_CREATE_SUBDOMAIN` has NOT been burned
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
