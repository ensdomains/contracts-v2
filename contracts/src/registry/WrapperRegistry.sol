// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {
    INameWrapper,
    CANNOT_UNWRAP,
    PARENT_CANNOT_CONTROL
} from "@ens/contracts/wrapper/INameWrapper.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {InvalidOwner} from "../CommonErrors.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {MigrationErrors} from "../migration/MigrationErrors.sol";
import {WrapperReceiver} from "../migration/WrapperReceiver.sol";
import {IWrapperRegistry} from "../registry/interfaces/IWrapperRegistry.sol";

import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRegistryMetadata} from "./interfaces/IRegistryMetadata.sol";
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {PermissionedRegistry} from "./PermissionedRegistry.sol";

uint32 constant EMANCIPATED = CANNOT_UNWRAP | PARENT_CANNOT_CONTROL;

contract WrapperRegistry is
    IWrapperRegistry,
    PermissionedRegistry,
    WrapperReceiver,
    Initializable,
    UUPSUpgradeable
{
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    address public immutable V1_RESOLVER;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    bytes32 public parentNode;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        INameWrapper nameWrapper,
        VerifiableFactory verifiableFactory,
        address ensV1Resolver,
        IHCAFactoryBasic hcaFactory,
        IRegistryMetadata metadataProvider
    )
        PermissionedRegistry(hcaFactory, metadataProvider, address(0), 0)
        WrapperReceiver(nameWrapper, verifiableFactory, address(this))
    {
        V1_RESOLVER = ensV1Resolver;
        _disableInitializers();
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(IERC165, WrapperReceiver, PermissionedRegistry) returns (bool) {
        return
            type(IWrapperRegistry).interfaceId == interfaceId ||
            type(UUPSUpgradeable).interfaceId == interfaceId ||
            super.supportsInterface(interfaceId);
    }

    /// @inheritdoc IWrapperRegistry
    function initialize(IWrapperRegistry.ConstructorArgs calldata args) public initializer {
        if (args.owner == address(0)) {
            revert InvalidOwner();
        }

        // Set the parent domain for name resolution fallback
        parentNode = args.node;

        // Configure owner with upgrade permissions and specified roles
        _grantRoles(
            ROOT_RESOURCE,
            RegistryRolesLib.ROLE_UPGRADE | RegistryRolesLib.ROLE_UPGRADE_ADMIN | args.ownerRoles,
            args.owner,
            false
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IWrapperRegistry
    function parentName() external view returns (bytes memory) {
        return NAME_WRAPPER.names(parentNode);
    }

    /// @inheritdoc PermissionedRegistry
    /// @dev Return `V1_RESOLVER` upon visiting migratable children.
    function getResolver(
        string calldata label
    ) public view override(IRegistry, PermissionedRegistry) returns (address) {
        return _isMigratableChild(label) ? V1_RESOLVER : super.getResolver(label);
    }

    /// @inheritdoc WrapperReceiver
    /// @dev Allow registration of emancipated children.
    function _inject(
        string memory label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) internal override returns (uint256 tokenId) {
        return
            super._register(label, owner, subregistry, resolver, roleBitmap, expiry, _msgSender()); // TODO: is this correct sender? address(this)?
    }

    /// @inheritdoc PermissionedRegistry
    /// @dev Prevent registration of emancipated children.
    function _register(
        string memory label,
        address owner,
        IRegistry registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry,
        address sender
    ) internal override returns (uint256 tokenId) {
        if (_isMigratableChild(label)) {
            revert MigrationErrors.NameNotMigrated(
                NameCoder.addLabel(NAME_WRAPPER.names(parentNode), label)
            );
        }
        return super._register(label, owner, registry, resolver, roleBitmap, expiry, sender);
    }

    /// @dev Allow `ROLE_UPGRADE` to upgrade.
    function _authorizeUpgrade(
        address
    ) internal override onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE) {
        //
    }

    function _parentNode() internal view override returns (bytes32) {
        return parentNode;
    }

    /// @dev Determine if `label` is emancipated but unmigrated.
    function _isMigratableChild(string memory label) internal view returns (bool) {
        bytes32 node = NameCoder.namehash(parentNode, keccak256(bytes(label)));
        (address ownerV1, uint32 fuses, ) = NAME_WRAPPER.getData(uint256(node));
        return ownerV1 != address(this) && (fuses & EMANCIPATED) == EMANCIPATED;
    }
}
