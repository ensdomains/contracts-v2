// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {
    IProxyAuthorization
} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {
    IVerifiableFactory
} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {
    Initializable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {
    UUPSUpgradeable
} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {
    AbstractWrapperReceiver
} from "../migration/AbstractWrapperReceiver.sol";
import {LibMigration} from "../migration/libraries/LibMigration.sol";
import {LockedWrapperReceiver} from "../migration/LockedWrapperReceiver.sol";
import {IWrapperRegistry} from "../registry/interfaces/IWrapperRegistry.sol";
import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {ApprovedUpgradeGate} from "./ApprovedUpgradeGate.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRegistryMetadata} from "./interfaces/IRegistryMetadata.sol";
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
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Upgrade target is not approved for `WrapperRegistry` proxies.
    /// @dev Error selector: `0xf74d7dd0`
    /// @param implementation The disallowed implementation address.
    error UpgradeTargetNotApproved(address implementation);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param nameWrapper The ENSv1 NameWrapper.
    /// @param graveyard The ENSv1 `BaseRegistrar` token graveyard.
    /// @param verifiableFactory The VerifiableFactory.
    /// @param ensV1Resolver The ENSv1 resolver.
    /// @param hcaFactory The HCA factory.
    /// @param metadataProvider The metadata provider.
    /// @param upgradeGate The upgrade target allowlist.
    /// @param labelStore The shared label database.
    constructor(
        INameWrapper nameWrapper,
        address graveyard,
        IVerifiableFactory verifiableFactory,
        address ensV1Resolver,
        IHCAFactoryBasic hcaFactory,
        IRegistryMetadata metadataProvider,
        ApprovedUpgradeGate upgradeGate,
        ILabelStore labelStore
    )
        PermissionedRegistry(
            hcaFactory,
            metadataProvider,
            labelStore,
            address(0),
            0
        ) // no roles are granted
        LockedWrapperReceiver(
            nameWrapper,
            graveyard,
            verifiableFactory,
            address(this)
        )
    {
        V1_RESOLVER = ensV1Resolver;
        UPGRADE_GATE = upgradeGate;
        _disableInitializers();
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    )
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
        address rootAccount,
        uint256 roleBitmap
    ) public initializer {
        _node = node;
        // setup canonical parent (ROLE_SET_PARENT is not granted)
        _parentRegistry = parentRegistry;
        _childLabel = childLabel;
        emit RegistryCreated();
        _grantRoles(ROOT_RESOURCE, roleBitmap, rootAccount, false);
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
    ) external pure virtual override returns (bool allowed) {
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
        return
            super.register(
                label,
                owner,
                registry,
                resolver,
                roleBitmap,
                expiry
            );
    }

    /// @inheritdoc PermissionedRegistry
    /// @dev Return `V1_RESOLVER` upon visiting migratable children.
    function getResolver(
        string calldata label
    ) public view override(IRegistry, PermissionedRegistry) returns (address) {
        return
            _isMigratableChild(label) ? V1_RESOLVER : super.getResolver(label);
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
    ) internal override returns (uint256 tokenId) {
        return
            _register(
                label,
                owner,
                subregistry,
                resolver,
                roleBitmap,
                expiry,
                false
            );
    }

    /// @dev Requires `ROLE_UPGRADE` and approval for the target implementation.
    function _authorizeUpgrade(
        address newImplementation
    ) internal view override onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE) {
        if (!UPGRADE_GATE.approvedImplementations(newImplementation)) {
            revert UpgradeTargetNotApproved(newImplementation);
        }
    }

    /// @inheritdoc LockedWrapperReceiver
    function _getRegistry() internal view override returns (IRegistry) {
        return this;
    }
}
