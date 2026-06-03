// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {AbstractWrapperReceiver} from "../migration/AbstractWrapperReceiver.sol";
import {LibMigration} from "../migration/libraries/LibMigration.sol";
import {LockedWrapperReceiver} from "../migration/LockedWrapperReceiver.sol";
import {IWrapperRegistry} from "../registry/interfaces/IWrapperRegistry.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {ApprovedUpgradeGate} from "./ApprovedUpgradeGate.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {IStandardRegistry} from "./interfaces/IStandardRegistry.sol";
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

/// @notice UUPS-upgradeable registry that wraps an ENSv1 NameWrapper, supporting migration of
///         wrapped names into the namechain registry system.
contract WrapperRegistry is
    IWrapperRegistry,
    PermissionedRegistry,
    LockedWrapperReceiver,
    Initializable,
    UUPSUpgradeable,
    IProxyAuthorization
{
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Fallback resolver for ENSv1 resolution.
    address public immutable V1_RESOLVER;

    /// @notice Gate for approved implementation upgrade targets.
    ApprovedUpgradeGate public immutable UPGRADE_GATE;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev The namehash of this registry.
    bytes32 internal _node;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param nameWrapper The ENSv1 NameWrapper.
    /// @param graveyard The ENSv1 `BaseRegistrar` token graveyard.
    /// @param verifiableFactory The VerifiableFactory.
    /// @param ensV1Resolver The ENSv1 resolver.
    /// @param hcaFactory The HCA factory.
    /// @param upgradeGate The upgrade target allowlist.
    /// @param labelStore The shared label database.
    /// @param publicResolverSet The approved list of `PublicResolver` contracts.
    /// @param publicResolver The replacement `PublicResolver`.
    /// @param namer The implementation namer.
    constructor(
        INameWrapper nameWrapper,
        address graveyard,
        IVerifiableFactory verifiableFactory,
        address ensV1Resolver,
        IHCAFactoryBasic hcaFactory,
        ApprovedUpgradeGate upgradeGate,
        ILabelStore labelStore,
        IAddressSet publicResolverSet,
        address publicResolver,
        address namer
    )
        PermissionedRegistry(
            hcaFactory,
            labelStore,
            namer,
            RegistryRolesLib.ROLE_CAN_NAME | RegistryRolesLib.ROLE_CAN_NAME_ADMIN
        )
        LockedWrapperReceiver(
            nameWrapper,
            graveyard,
            verifiableFactory,
            address(this),
            publicResolverSet,
            publicResolver
        )
    {
        V1_RESOLVER = ensV1Resolver;
        UPGRADE_GATE = upgradeGate;
        _disableInitializers();
    }

    /// @inheritdoc IERC165
    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(IERC165, AbstractWrapperReceiver, PermissionedRegistry)
        returns (bool)
    {
        return
            type(IWrapperRegistry).interfaceId == interfaceId ||
            type(UUPSUpgradeable).interfaceId == interfaceId ||
            type(IProxyAuthorization).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IWrapperRegistry
    function initialize(
        bytes32 node,
        IRegistry parentRegistry,
        string calldata childLabel,
        uint256 roleBitmap
    )
        public
        initializer
    {
        _node = node;
        // setup canonical parent (ROLE_SET_PARENT is not granted)
        _parentRegistry = parentRegistry;
        _childLabel = childLabel;
        emit RegistryCreated();
        address virtualOwner = address(_parentRegistry);
        emit ParentUpdated(parentRegistry, childLabel, virtualOwner);
        _grantRoles(ROOT_RESOURCE, roleBitmap, virtualOwner, false);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Declares this implementation as an eligible verifiable proxy upgrade target.
    /// @dev Upgrade authorization is still enforced by the current implementation during the UUPS
    ///      upgrade call, including the wrapper upgrade target allowlist.
    /// @param {previousImplementation} Ignored.
    /// @return allowed Always `true` for implementations in this wrapper registry family.
    function canUpgradeFrom(
        address /* previousImplementation */
    )
        external
        pure
        virtual
        override
        returns (bool allowed)
    {
        return true;
    }

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

    /// @inheritdoc PermissionedRegistry
    /// @dev Respect virtual owner.
    function isContractNamer(address namer)
        public
        view
        override(IContractNamer, PermissionedRegistry)
        returns (bool)
    {
        return hasRootRoles(RegistryRolesLib.ROLE_CAN_NAME, namer);
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
    /// * if root and operator is token owner, remap to virtual owner.
    ///
    function _checkedRoles(uint256 resource, address operator)
        internal
        view
        override
        returns (uint256 roleBitmap)
    {
        roleBitmap = super._checkedRoles(resource, operator);
        if (resource == ROOT_RESOURCE) {
            address parent = address(_parentRegistry); // virtual owner
            if (
                parent != address(0) &&
                operator == PermissionedRegistry(parent).findOwner(_childLabel)
            ) {
                roleBitmap |= super._checkedRoles(resource, parent);
            }
        }
    }

    /// @dev Requires `ROLE_UPGRADE` and approval for the target implementation.
    function _authorizeUpgrade(address newImplementation)
        internal
        view
        override
        onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE)
    {
        if (!UPGRADE_GATE.approvedImplementations(newImplementation)) {
            revert UpgradeTargetNotApproved(newImplementation);
        }
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
        (, uint32 fuses, ) = NAME_WRAPPER.getData(uint256(node));
        // NameWrapper preserves fuses across `_burn()`, so the PARENT_CANNOT_CONTROL
        // bit stays readable after unwrap and is the primary signal. Require an
        // active v1 registry owner.  A null owner means the subname was ABANDONED
        // and reserving the label would lock it forever; positive expiry on either
        // side marks a completed migration.
        return LibMigration.isEmancipatedChild(fuses) && _REGISTRY_V1.owner(node) != address(0);
    }
}
