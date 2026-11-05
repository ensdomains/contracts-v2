// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {AbstractWrapperReceiver} from "../migration/AbstractWrapperReceiver.sol";
import {LibMigration} from "../migration/libraries/LibMigration.sol";
import {LockedWrapperReceiver} from "../migration/LockedWrapperReceiver.sol";
import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {
    AbstractUpgradeablePermissionedRegistry
} from "./AbstractUpgradeablePermissionedRegistry.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";
import {IStandardRegistry} from "./interfaces/IStandardRegistry.sol";
import {IWrapperRegistry} from "./interfaces/IWrapperRegistry.sol";
import {IWrapperRegistryInitializable} from "./interfaces/IWrapperRegistryInitializable.sol";
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

/// @notice UUPS-upgradeable registry that wraps an ENSv1 NameWrapper, supporting migration of
///         wrapped names into the namechain registry system.
contract WrapperRegistry is
    AbstractUpgradeablePermissionedRegistry,
    LockedWrapperReceiver,
    IWrapperRegistry,
    IWrapperRegistryInitializable
{
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev Constructor arguments for `WrapperRegistry`.
    struct ConstructorArgs {
        // *** LockedWrapperReceiver ***
        /// @param nameWrapper ENSv1 `NameWrapper`.
        INameWrapper nameWrapper;
        /// @param graveyard ENSv1 `BaseRegistrar` token graveyard.
        address graveyard;
        /// @param verifiableFactory The `VerifiableFactory`.
        IVerifiableFactory verifiableFactory;
        /// @param publicResolverSet List of replaceable `PublicResolver` contracts.
        IAddressSet publicResolverSet;
        /// @param publicResolver Replacement for `PublicResolver`.
        address publicResolver;
        // *** AbstractUpgradeablePermissionedRegistry ***
        /// @param labelStore The shared label database.
        ILabelStore labelStore;
        /// @param namer The implementation namer.
        address namer;
        /// @param upgradeSet Upgrade target allowlist.
        IAddressSet upgradeSet;
        /// @param upgradeable List of upgradeable implementations.
        address[] upgradeable;
        // *** WrapperRegistry ***
        /// @param ensV1Resolver Fallback resolver for ENSv1 resolution.
        address ensV1Resolver;
        /// @param uriRenderer Fixed URI renderer.
        IRegistryURIRenderer uriRenderer;
    }

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Fallback resolver for ENSv1 resolution.
    address public immutable V1_RESOLVER;

    /// @notice Fixed URI renderer.
    IRegistryURIRenderer public immutable URI_RENDERER;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev The namehash of this registry.
    bytes32 internal _node;

    /// @dev The initial roles derived from the NameWrapper.
    uint256 internal _initialRoleBitmap;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param ca Constructor arguments.
    constructor(ConstructorArgs memory ca)
        AbstractUpgradeablePermissionedRegistry(
            ca.labelStore,
            ca.namer,
            ca.upgradeSet,
            ca.upgradeable
        )
        LockedWrapperReceiver(
            ca.nameWrapper,
            ca.graveyard,
            ca.verifiableFactory,
            address(this),
            ca.publicResolverSet,
            ca.publicResolver
        )
    {
        V1_RESOLVER = ca.ensV1Resolver;
        URI_RENDERER = ca.uriRenderer;
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(IERC165, AbstractWrapperReceiver, AbstractUpgradeablePermissionedRegistry)
        returns (bool)
    {
        return
            type(IWrapperRegistry).interfaceId == interfaceId ||
            type(IWrapperRegistryInitializable).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IWrapperRegistryInitializable
    function initialize(bytes32 node, IRegistry parentRegistry) public initializer {
        // derive from wrapper
        uint32 fuses = _getFuses(node);
        if (!LibMigration.isLocked(fuses)) {
            revert LibMigration.NameNotLocked(uint256(node));
        }
        string memory childLabel = NameCoder.firstLabel(NAME_WRAPPER.names(node)); // exists if locked
        uint256 roleBitmap = _subregistryRoleBitmapFromFuses(fuses);
        _node = node;
        // setup canonical parent (ROLE_SET_PARENT is not granted)
        _parentRegistry = parentRegistry;
        _childLabel = childLabel;
        _initialRoleBitmap = roleBitmap;
        emit RegistryCreated();
        address virtualOwner = address(_parentRegistry);
        emit ParentUpdated(parentRegistry, childLabel, address(0));
        _grantRoles(ROOT_RESOURCE, roleBitmap, virtualOwner, false);
        _uriRenderer = URI_RENDERER;
        emit URIUpdated("", address(URI_RENDERER), address(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc PermissionedRegistry
    /// @dev Blocks registration of emancipated children.
    function register(
        string memory label,
        address owner,
        IRegistry registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    )
        public
        override(IStandardRegistry, PermissionedRegistry)
        returns (uint256 tokenId)
    {
        if (_isMigratableChild(label)) {
            revert LibMigration.NameRequiresMigration();
        }
        return super.register(label, owner, registry, resolver, roleBitmap, expiry);
    }

    /// @inheritdoc PermissionedRegistry
    /// @dev Return `V1_RESOLVER` upon visiting migratable children.
    function getResolver(string calldata label)
        public
        view
        override(IRegistry, PermissionedRegistry)
        returns (address)
    {
        return _isMigratableChild(label) ? V1_RESOLVER : super.getResolver(label);
    }

    /// @inheritdoc IWrapperRegistry
    function getWrappedName()
        public
        view
        override(LockedWrapperReceiver, IWrapperRegistry)
        returns (bytes memory)
    {
        return super.getWrappedName();
    }

    /// @inheritdoc IWrapperRegistry
    function getWrappedNode()
        public
        view
        override(LockedWrapperReceiver, IWrapperRegistry)
        returns (bytes32)
    {
        return _node;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc LockedWrapperReceiver
    /// @dev Allows registration of emancipated children.
    function _inject(
        string memory label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    )
        internal
        override
        returns (uint256 tokenId)
    {
        return _register(label, owner, subregistry, resolver, roleBitmap, expiry, false);
    }

    /// @inheritdoc PermissionedRegistry
    /// @dev Override for token-dependent logic:
    ///
    /// Root admin roles cannot be granted.
    ///
    /// @param resource The resource to get settable roles for.
    /// @param account The account to get settable roles for.
    /// @return The settable roles.
    function _getSettableRoles(uint256 resource, address account)
        internal
        view
        override
        returns (uint256)
    {
        uint256 roleBitmap = super._getSettableRoles(resource, account);
        return resource == ROOT_RESOURCE ? roleBitmap >> 128 : roleBitmap;
    }

    /// @inheritdoc PermissionedRegistry
    /// @dev Override for token-dependent logic:
    ///
    /// * if root and account is token owner or approved, remap to virtual owner.
    ///
    function _getRoles(uint256 resource, address account) internal view override returns (uint256) {
        if (resource == ROOT_RESOURCE) {
            address parent = address(_parentRegistry); // virtual owner
            if (parent != address(0)) {
                address owner = PermissionedRegistry(parent).findOwner(_childLabel);
                if (
                    account == owner ||
                    PermissionedRegistry(parent).isApprovedForAll(owner, account)
                ) {
                    account = parent; // replace, instead of OR
                }
            }
        }
        return super._getRoles(resource, account);
    }

    /// @dev Override to prevent revive if `CANNOT_CREATE_SUBDOMAIN` fuse was burned.
    function _canRevive(uint256 tokenId, address sender) internal view override returns (bool) {
        return
            (_initialRoleBitmap & RegistryRolesLib.ROLE_REGISTRAR) != 0 &&
            super._canRevive(tokenId, sender);
    }

    /// @inheritdoc LockedWrapperReceiver
    function _getRegistry() internal view override returns (IRegistry) {
        return this;
    }

    /// @dev Determine if `label` is emancipated but not-yet migrated.
    function _isMigratableChild(string memory label) internal view returns (bool) {
        uint256 labelId = LibLabel.id(label);
        if (getExpiry(labelId) > 0) {
            return false; // has been registered before, v2 is authority
        }
        bytes32 node = NameCoder.namehash(_node, bytes32(labelId));
        // NameWrapper preserves fuses across `_burn()`, so the PARENT_CANNOT_CONTROL
        // bit stays readable after unwrap and is the primary signal. Require an
        // active v1 registry owner.  A null owner means the subname was ABANDONED
        // and reserving the label would lock it forever; positive expiry on either
        // side marks a completed migration.
        return
            LibMigration.isEmancipatedChild(_getFuses(node)) &&
            _REGISTRY_V1.owner(node) != address(0);
    }

    /// @dev Convenience for `NameWrapper` fuses.
    function _getFuses(bytes32 node) internal view returns (uint32 fuses) {
        (, fuses, ) = NAME_WRAPPER.getData(uint256(node));
    }
}
