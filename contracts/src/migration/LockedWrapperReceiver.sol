// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {
    INameWrapper,
    CAN_EXTEND_EXPIRY,
    CANNOT_UNWRAP,
    CANNOT_BURN_FUSES,
    CANNOT_TRANSFER,
    CANNOT_SET_RESOLVER,
    CANNOT_SET_TTL,
    CANNOT_CREATE_SUBDOMAIN
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {IWrapperRegistry} from "../registry/interfaces/IWrapperRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";

import {AbstractWrapperReceiver} from "./AbstractWrapperReceiver.sol";
import {LibMigration} from "./libraries/LibMigration.sol";

/// @dev Fuses which translate directly to PermissionedRegistry logic.
uint32 constant FUSES_TO_BURN = CANNOT_BURN_FUSES |
    CANNOT_TRANSFER |
    CANNOT_SET_RESOLVER |
    CANNOT_SET_TTL |
    CANNOT_CREATE_SUBDOMAIN;

/// @title LockedWrappedReceiver
/// @notice Abstract IERC1155Receiver which handles locked NameWrapper token migration via transfer.
///
/// There are (2) LockedWrapperReceivers:
/// 1. LockedMigrationController only accepts .eth 2LD tokens.
/// 2. WrapperRegistry only accepts emancipated (N+1)-LD children with a matching N-LD parent node.
///
/// eg. transfer("nick.eth") => LockedMigrationController
///     ↪ ETHRegistry.subregistry("nick") = WrapperRegistry("nick.eth")
///     transfer("sub.nick.eth") => WrapperRegistry("nick.eth")
///     ↪ WrapperRegistry("nick.eth").subregistry("sub") = WrapperRegistry("sub.nick.eth")
///     transfer("abc.sub.nick.eth") => WrapperRegistry("sub.nick.eth")
///     ↪ WrapperRegistry("sub.nick.eth").subregistry("abc") = WrapperRegistry("abc.sub.nick.eth")
///
/// Upon successful migration:
/// * subregistry is bound to a WrapperRegistry (token does not have `SET_SUBREGISTRY` role)
/// * subregistry knows the parent node (namehash)
/// * subregistry migrates children of the same parent
///
/// @dev Interface selector: `0xf8ff8404`
abstract contract LockedWrapperReceiver is AbstractWrapperReceiver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    VerifiableFactory public immutable VERIFIABLE_FACTORY;
    address public immutable WRAPPER_REGISTRY_IMPL;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        INameWrapper nameWrapper,
        VerifiableFactory verifiableFactory,
        address wrapperRegistryImpl
    ) AbstractWrapperReceiver(nameWrapper) {
        VERIFIABLE_FACTORY = verifiableFactory;
        WRAPPER_REGISTRY_IMPL = wrapperRegistryImpl;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(LockedWrapperReceiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice The DNS-encoded name of the parent registry.
    function getParentName() external view returns (bytes memory) {
        return NAME_WRAPPER.names(_parentNode());
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc AbstractWrapperReceiver
    function _migrateWrapped(
        uint256[] calldata ids,
        LibMigration.Data[] calldata mds
    ) internal override {
        bytes32 parentNode = _parentNode();
        for (uint256 i; i < ids.length; ++i) {
            LibMigration.Data memory md = mds[i];
            if (md.owner == address(0)) {
                revert IERC1155Errors.ERC1155InvalidReceiver(md.owner);
            }
            bytes32 node = bytes32(ids[i]);
            bytes32 labelHash = keccak256(bytes(md.label));
            if (node != NameCoder.namehash(parentNode, labelHash)) {
                revert LibMigration.NameDataMismatch(uint256(node));
            }
            // by construction: 1 <= length(label) <= 255
            // same as NameCoder.assertLabelSize()
            // see: V1Fixture.t.sol: `test_nameWrapper_labelTooShort()` and `test_nameWrapper_labelTooLong()`.

            (address owner, uint32 fuses, uint64 expiry) = NAME_WRAPPER.getData(uint256(node));
            if (!_isLocked(fuses)) {
                revert LibMigration.NameNotLocked(uint256(node));
            }
            assert(owner == address(this)); // claim: only we can call this function => we own the token
            assert(expiry >= block.timestamp); // claim: expired names cannot be transferred

            if ((fuses & CANNOT_SET_RESOLVER) != 0) {
                md.resolver = _REGISTRY_V1.resolver(node); // replace with V1 resolver
            } else {
                NAME_WRAPPER.setResolver(node, address(0)); // clear V1 resolver
            }

            (
                bool fusesFrozen,
                uint256 tokenRoles,
                uint256 registryRoles
            ) = _generateRoleBitmapsFromFuses(fuses);
            // PermissionedRegistry._register() => _grantRoles() => _checkRoleBitmap() :: roles are correct by construction

            // create subregistry
            IRegistry subregistry = IRegistry(
                VERIFIABLE_FACTORY.deployProxy(
                    WRAPPER_REGISTRY_IMPL,
                    md.salt,
                    abi.encodeCall(
                        IWrapperRegistry.initialize,
                        (
                            IWrapperRegistry.ConstructorArgs({
                                node: node,
                                admin: md.owner,
                                roleBitmap: registryRoles
                            })
                        )
                    )
                )
            );

            // add name to V2
            _inject(md.label, md.owner, subregistry, md.resolver, tokenRoles, expiry);
            // PermissionedRegistry._register() => CannotSetPastExpiration :: see expiry check
            // PermissionedRegistry._register() => NameAlreadyRegistered :: only have ROLE_REGISTER_RESERVED
            // ERC1155._safeTransferFrom() => ERC1155InvalidReceiver :: see owner check

            // Burn all migration fuses
            if (!fusesFrozen) {
                NAME_WRAPPER.setFuses(node, uint16(FUSES_TO_BURN));
            }
        }
    }

    /// @dev Abstract function for registering a locked name.
    function _inject(
        string memory label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) internal virtual returns (uint256 tokenId);

    /// @dev Abstract function for the node (namehash) of the parent registry.
    ///      Equivalent to token ID of the parent NameWrapper token.
    function _parentNode() internal view virtual returns (bytes32);

    /// @dev Determine if `label` is emancipated but not-yet migrated.
    function _isMigratableChild(string memory label) internal view returns (bool) {
        bytes32 node = NameCoder.namehash(_parentNode(), keccak256(bytes(label)));
        (address ownerV1, uint32 fuses, ) = NAME_WRAPPER.getData(uint256(node));
        return ownerV1 != address(this) && (fuses & CANNOT_UNWRAP) != 0;
    }

    /// @notice Generates role bitmaps based on fuses.
    /// @param fuses The current fuses on the name
    /// @return fusesFrozen True if fuses are frozen.
    /// @return tokenRoles The token roles in parent registry.
    /// @return registryRoles The root roles in token subregistry.
    function _generateRoleBitmapsFromFuses(
        uint32 fuses
    ) internal pure returns (bool fusesFrozen, uint256 tokenRoles, uint256 registryRoles) {
        // Check if fuses are permanently frozen
        fusesFrozen = (fuses & CANNOT_BURN_FUSES) != 0;

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
            registryRoles |= RegistryRolesLib.ROLE_REGISTRAR;
            if (!fusesFrozen) {
                registryRoles |= RegistryRolesLib.ROLE_REGISTRAR_ADMIN;
            }
        }

        // Add renewal roles to subregistry
        registryRoles |= RegistryRolesLib.ROLE_RENEW;
        registryRoles |= RegistryRolesLib.ROLE_RENEW_ADMIN;
    }
}
