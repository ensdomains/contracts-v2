// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {IEnhancedAccessControl} from "../access-control/interfaces/IEnhancedAccessControl.sol";
import {ERC1155Singleton} from "../erc1155/ERC1155Singleton.sol";
import {IERC1155Singleton} from "../erc1155/interfaces/IERC1155Singleton.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {IPermissionedRegistry} from "./interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRegistryMetadata} from "./interfaces/IRegistryMetadata.sol";
import {IStandardRegistry} from "./interfaces/IStandardRegistry.sol";
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {MetadataMixin} from "./MetadataMixin.sol";

/// @notice A tokenized (ERC1155) registry with resource-scoped access control for subdomain management.
///
/// Many functions accept an `anyId` parameter that can be a labelhash, tokenId, or resource
/// interchangeably. Internally, `_entry()` zeroes version bits (via `LibLabel.withVersion(anyId, 0)`)
/// to resolve any of these to the canonical storage slot for the name.
///
/// The registry maintains two independent version counters per name:
///   - `eacVersionId`: incremented on unregister/re-register. Combined with the labelhash to form
///     the EAC resource ID. This means a re-registered name gets a fresh permission scope.
///   - `tokenVersionId`: incremented on unregister and whenever the token is regenerated (burn + mint)
///     due to role changes. Combined with the labelhash to form the ERC1155 token ID, ensuring
///     changes to roles create new tokens and prevent frontrunning a transfer with a role revocation.
///
/// Names are treated as `AVAILABLE` once `block.timestamp >= expiry`.
///
/// State diagram:
///
///                      register()
///                   +ROLE_REGISTRAR
///       +------------------->----------------------+
///       |                                          |
///       |                renew()                   |    renew()
///       |              +ROLE_RENEW                 |  +ROLE_RENEW
///       |               +------+                   |   +------+
///       |               |      |                   |   |      |
///       ʌ               ʌ      v                   v   v      |
///   AVAILABLE --------> RESERVED -------------> REGISTERED >--+
///       ʌ    register()    v       register()        v
///       |    w/owner=0     | +ROLE_REGISTER_RESERVED |
///       | +ROLE_REGISTRAR  |                         |
///       |                  |                         |
///       +--------<---------+------------<------------+
///                     unregister()
///                  +ROLE_UNREGISTER
///
contract PermissionedRegistry is
    IRegistry,
    ERC1155Singleton,
    EnhancedAccessControl,
    IPermissionedRegistry,
    MetadataMixin
{
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    struct Entry {
        /// @dev Incremented on unregister; combined with labelhash to form the EAC resource ID.
        uint32 eacVersionId;
        /// @dev Incremented on unregister and on token regeneration; combined with labelhash to form the ERC1155 token ID.
        uint32 tokenVersionId;
        /// @dev Child registry for this name.
        IRegistry subregistry;
        /// @dev Timestamp at or after which the name is considered expired/available.
        uint64 expiry;
        /// @dev Resolver address for this name.
        address resolver;
    }

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev The parent registry of this registry.
    IRegistry internal _parentRegistry;
    /// @dev The child label of this registry.
    string internal _childLabel;
    /// @dev The entries of this registry.
    mapping(uint256 storageId => Entry entry) internal _entries;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the PermissionedRegistry.
    /// @param hcaFactory The HCA factory to use.
    /// @param metadata The metadata provider to use.
    /// @param ownerAddress The address that will receive the specified roles.
    /// @param ownerRoles The roles to grant to `ownerAddress`.
    constructor(
        IHCAFactoryBasic hcaFactory,
        IRegistryMetadata metadata,
        address ownerAddress,
        uint256 ownerRoles
    ) HCAEquivalence(hcaFactory) MetadataMixin(metadata) {
        _grantRoles(ROOT_RESOURCE, ownerRoles, ownerAddress, false);
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    )
        public
        view
        virtual
        override(IERC165, ERC1155Singleton, EnhancedAccessControl)
        returns (bool)
    {
        return
            interfaceId == type(IPermissionedRegistry).interfaceId ||
            interfaceId == type(IStandardRegistry).interfaceId ||
            interfaceId == type(IRegistry).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IStandardRegistry
    function setSubregistry(uint256 anyId, IRegistry registry) public virtual {
        (uint256 tokenId, Entry storage entry) = _checkExpiryAndTokenRoles(
            anyId,
            RegistryRolesLib.ROLE_SET_SUBREGISTRY
        );
        entry.subregistry = registry;
        emit SubregistryUpdated(tokenId, registry, _msgSender());
    }

    /// @inheritdoc IStandardRegistry
    function setResolver(uint256 anyId, address resolver) public virtual {
        (uint256 tokenId, Entry storage entry) = _checkExpiryAndTokenRoles(
            anyId,
            RegistryRolesLib.ROLE_SET_RESOLVER
        );
        entry.resolver = resolver;
        emit ResolverUpdated(tokenId, resolver, _msgSender());
    }

    /// @inheritdoc IStandardRegistry
    function setParent(
        IRegistry parent,
        string memory label
    ) public virtual onlyRootRoles(RegistryRolesLib.ROLE_SET_PARENT) {
        _parentRegistry = parent;
        _childLabel = label;
        emit ParentUpdated(parent, label, _msgSender());
    }

    /// @inheritdoc IStandardRegistry
    /// @dev If `AVAILABLE`, requires `ROLE_REGISTRAR` on root.
    ///         * If `owner` is null (`roleBitmap` must be 0), status becomes `RESERVED` instead of `REGISTERED`.
    ///      If `RESERVED`, requires `ROLE_REGISTER_RESERVED` on root.
    ///         * If `expiry` is 0, uses current expiry.
    function register(
        string memory label,
        address owner,
        IRegistry registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) public virtual override returns (uint256 tokenId) {
        NameCoder.assertLabelSize(label);
        uint256 labelId = LibLabel.id(label);
        Entry storage entry = _entry(labelId);
        tokenId = _constructTokenId(labelId, entry);
        address prevOwner = super.ownerOf(tokenId);
        address sender = _msgSender(); // the registrar, not the registrant
        if (_isExpired(entry.expiry)) {
            if (sender != address(this)) {
                _checkRoles(ROOT_RESOURCE, RegistryRolesLib.ROLE_REGISTRAR, sender);
            }
            if (owner == address(0) && roleBitmap != 0) {
                revert EACCannotGrantRoles(ROOT_RESOURCE, roleBitmap, sender); // strict
            }
        } else {
            if (prevOwner != address(0)) {
                revert LabelAlreadyRegistered(label); // cannot overwrite REGISTERED
            } else if (owner == address(0)) {
                revert LabelAlreadyReserved(label); // cannot reserve/register RESERVED
            }
            if (sender != address(this)) {
                _checkRoles(ROOT_RESOURCE, RegistryRolesLib.ROLE_REGISTER_RESERVED, sender);
            }
            if (expiry == 0) {
                expiry = entry.expiry; // use current expiry
            }
        }
        if (_isExpired(expiry)) {
            revert CannotSetPastExpiry(expiry);
        }
        if (prevOwner != address(0)) {
            _burn(prevOwner, tokenId, 1);
            ++entry.eacVersionId;
            ++entry.tokenVersionId;
            tokenId = _constructTokenId(tokenId, entry);
        }
        entry.expiry = expiry;
        entry.subregistry = registry;
        entry.resolver = resolver;
        // emit LabelRegistered before mint so we can determine this is a registry (in an indexer)
        if (owner == address(0)) {
            emit LabelReserved(tokenId, bytes32(labelId), label, expiry, sender);
        } else {
            emit LabelRegistered(tokenId, bytes32(labelId), label, owner, expiry, sender);
            _mint(owner, tokenId, 1, "");
            uint256 resource = _constructResource(tokenId, entry);
            emit TokenResource(tokenId, resource);
            _grantRoles(resource, roleBitmap, owner, false);
        }
        if (address(registry) != address(0)) {
            emit SubregistryUpdated(tokenId, registry, sender);
        }
        if (address(resolver) != address(0)) {
            emit ResolverUpdated(tokenId, resolver, sender);
        }
    }

    /// @inheritdoc IStandardRegistry
    /// @dev Requires `REGISTERED | RESERVED` and `ROLE_UNREGISTER`.
    function unregister(uint256 anyId) public virtual {
        (uint256 tokenId, Entry storage entry) = _checkExpiryAndTokenRoles(
            anyId,
            RegistryRolesLib.ROLE_UNREGISTER
        );
        emit LabelUnregistered(tokenId, _msgSender());
        address owner = super.ownerOf(tokenId);
        if (owner != address(0)) {
            _burn(owner, tokenId, 1);
            ++entry.eacVersionId;
            ++entry.tokenVersionId;
        }
        entry.expiry = uint64(block.timestamp);
    }

    /// @inheritdoc IStandardRegistry
    /// @dev Requires active or (ROOT and expired) `REGISTERED | RESERVED` and `ROLE_RENEW`.
    function renew(uint256 anyId, uint64 newExpiry) public override {
        Entry storage entry = _entry(anyId);
        uint256 tokenId = _constructTokenId(anyId, entry);
        address sender = _msgSender();
        uint64 expiry = entry.expiry;
        if (_isExpired(expiry)) {
            if (expiry == 0 || !hasRoles(ROOT_RESOURCE, RegistryRolesLib.ROLE_RENEW, sender)) {
                revert LabelExpired(tokenId);
            }
        } else {
            _checkRoles(_constructResource(anyId, entry), RegistryRolesLib.ROLE_RENEW, sender);
        }
        if (newExpiry < expiry) {
            revert CannotReduceExpiry(expiry, newExpiry);
        }
        entry.expiry = newExpiry;
        emit ExpiryUpdated(tokenId, newExpiry, sender);
    }

    /// @inheritdoc IEnhancedAccessControl
    function grantRoles(
        uint256 anyId,
        uint256 roleBitmap,
        address account
    ) public override(EnhancedAccessControl, IEnhancedAccessControl) returns (bool) {
        return super.grantRoles(getResource(anyId), roleBitmap, account);
    }

    /// @inheritdoc IEnhancedAccessControl
    function revokeRoles(
        uint256 anyId,
        uint256 roleBitmap,
        address account
    ) public override(EnhancedAccessControl, IEnhancedAccessControl) returns (bool) {
        return super.revokeRoles(getResource(anyId), roleBitmap, account);
    }

    /// @inheritdoc IRegistry
    function getSubregistry(string calldata label) public view virtual returns (IRegistry) {
        Entry storage entry = _entry(LibLabel.id(label));
        return _isExpired(entry.expiry) ? IRegistry(address(0)) : entry.subregistry;
    }

    /// @inheritdoc IRegistry
    function getResolver(string calldata label) public view virtual returns (address) {
        Entry storage entry = _entry(LibLabel.id(label));
        return _isExpired(entry.expiry) ? address(0) : entry.resolver;
    }

    /// @inheritdoc IRegistry
    function getParent() public view virtual returns (IRegistry parent, string memory label) {
        return (_parentRegistry, _childLabel);
    }

    /// @inheritdoc ERC1155Singleton
    function uri(uint256 tokenId) public view override returns (string memory) {
        return _tokenURI(tokenId);
    }

    /// @inheritdoc IStandardRegistry
    function getExpiry(uint256 anyId) public view returns (uint64) {
        return _entry(anyId).expiry;
    }

    /// @inheritdoc IPermissionedRegistry
    function getResource(uint256 anyId) public view returns (uint256) {
        return _constructResource(anyId, _entry(anyId));
    }

    /// @inheritdoc IPermissionedRegistry
    function getTokenId(uint256 anyId) public view returns (uint256) {
        return _constructTokenId(anyId, _entry(anyId));
    }

    /// @inheritdoc IPermissionedRegistry
    function getStatus(uint256 anyId) public view returns (Status) {
        Entry storage entry = _entry(anyId);
        return _constructStatus(entry.expiry, super.ownerOf(_constructTokenId(anyId, entry)));
    }

    /// @inheritdoc IPermissionedRegistry
    function getState(uint256 anyId) public view returns (State memory state) {
        Entry storage entry = _entry(anyId);
        uint64 expiry = entry.expiry;
        state.expiry = expiry;
        uint256 tokenId = _constructTokenId(anyId, entry);
        state.tokenId = tokenId;
        state.resource = _constructResource(anyId, entry);
        address owner = super.ownerOf(tokenId);
        state.latestOwner = owner;
        state.status = _constructStatus(expiry, owner);
    }

    /// @inheritdoc IPermissionedRegistry
    function latestOwnerOf(uint256 tokenId) public view virtual returns (address) {
        return super.ownerOf(tokenId);
    }

    /// @inheritdoc IERC1155Singleton
    function ownerOf(
        uint256 tokenId
    ) public view virtual override(ERC1155Singleton, IERC1155Singleton) returns (address) {
        Entry storage entry = _entry(tokenId);
        return
            tokenId != _constructTokenId(tokenId, entry) || _isExpired(entry.expiry)
                ? address(0)
                : super.ownerOf(tokenId);
    }

    /// @dev EAC view overrides — each translates `anyId` to the canonical EAC resource
    ///      (via `getResource`) before delegating to the base `EnhancedAccessControl` implementation.

    /// @inheritdoc IEnhancedAccessControl
    function roles(
        uint256 anyId,
        address account
    ) public view override(EnhancedAccessControl, IEnhancedAccessControl) returns (uint256) {
        return super.roles(getResource(anyId), account);
    }

    /// @inheritdoc IEnhancedAccessControl
    function roleCount(
        uint256 anyId
    ) public view override(EnhancedAccessControl, IEnhancedAccessControl) returns (uint256) {
        return super.roleCount(getResource(anyId));
    }

    /// @inheritdoc IEnhancedAccessControl
    function hasRoles(
        uint256 anyId,
        uint256 roleBitmap,
        address account
    ) public view override(EnhancedAccessControl, IEnhancedAccessControl) returns (bool) {
        return super.hasRoles(getResource(anyId), roleBitmap, account);
    }

    /// @inheritdoc IEnhancedAccessControl
    function hasAssignees(
        uint256 anyId,
        uint256 roleBitmap
    ) public view override(EnhancedAccessControl, IEnhancedAccessControl) returns (bool) {
        return super.hasAssignees(getResource(anyId), roleBitmap);
    }

    /// @inheritdoc IEnhancedAccessControl
    function getAssigneeCount(
        uint256 anyId,
        uint256 roleBitmap
    )
        public
        view
        override(EnhancedAccessControl, IEnhancedAccessControl)
        returns (uint256 counts, uint256 mask)
    {
        return super.getAssigneeCount(getResource(anyId), roleBitmap);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Override `ERC1155Singleton._update()` to transfer the roles to the new owner if the token is transferred.
    function _update(
        address from,
        address to,
        uint256[] memory tokenIds,
        uint256[] memory amounts
    ) internal virtual override {
        bool externalTransfer = to != address(0) && from != address(0); // skip mint and burn
        if (externalTransfer) {
            // only check ROLE_CAN_TRANSFER_ADMIN on token owner (from)
            for (uint256 i; i < tokenIds.length; ++i) {
                if (!hasRoles(tokenIds[i], RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN, from)) {
                    revert TransferDisallowed(tokenIds[i], from);
                }
            }
        }
        super._update(from, to, tokenIds, amounts); // ensures amounts[i] is 0 or 1
        if (externalTransfer) {
            for (uint256 i; i < tokenIds.length; ++i) {
                if (amounts[i] > 0) {
                    _transferRoles(getResource(tokenIds[i]), from, to, false);
                }
            }
        }
    }

    /// @dev Override the base registry _onRolesGranted function to regenerate the token when the roles are granted.
    function _onRolesGranted(
        uint256 resource,
        address /*account*/,
        uint256 /*oldRoles*/,
        uint256 /*newRoles*/,
        uint256 /*roleBitmap*/
    ) internal virtual override {
        _regenerate(resource);
    }

    /// @dev Override the base registry _onRolesRevoked function to regenerate the token when the roles are revoked.
    function _onRolesRevoked(
        uint256 resource,
        address /*account*/,
        uint256 /*oldRoles*/,
        uint256 /*newRoles*/,
        uint256 /*roleBitmap*/
    ) internal virtual override {
        _regenerate(resource);
    }

    /// @dev Bump `tokenVersionId` via burn+mint if token is not expired.
    function _regenerate(uint256 resource) internal {
        if (resource != ROOT_RESOURCE) {
            Entry storage entry = _entry(resource);
            uint256 tokenId = _constructTokenId(resource, entry);
            address owner = super.ownerOf(tokenId); // grant/revoke only on registered
            _burn(owner, tokenId, 1);
            ++entry.tokenVersionId;
            uint256 newTokenId = _constructTokenId(tokenId, entry);
            _mint(owner, newTokenId, 1, "");
            emit TokenRegenerated(tokenId, newTokenId); // resource is unchanged
        }
    }

    /// @inheritdoc EnhancedAccessControl
    /// @dev Override for token-dependent logic:
    ///
    /// Token non-admin roles can only be granted to registered tokens.
    ///
    /// Token admin roles are only assigned during name registration to maintain
    /// controlled permission management. This ensures that role delegation
    /// follows the intended security model where admin privileges are granted at
    /// registration time and cannot be arbitrarily granted afterward.
    ///
    /// Root admin roles are unaffected.
    ///
    /// @param resource The resource to get settable roles for.
    /// @param account The account to get settable roles for.
    /// @return The settable roles (regular roles only, not admin roles).
    function _getSettableRoles(
        uint256 resource,
        address account
    ) internal view virtual override returns (uint256) {
        uint256 roleBitmap = super._getSettableRoles(resource, account);
        if (resource == ROOT_RESOURCE) {
            return roleBitmap;
        } else if (ownerOf(_constructTokenId(resource, _entry(resource))) == address(0)) {
            return 0; // available or reserved
        }
        return roleBitmap >> 128; // remove admin
    }

    /// @inheritdoc EnhancedAccessControl
    /// @dev Override for token-dependent logic:
    ///
    /// Token roles can only be revoked from registered tokens.
    ///
    /// Root roles are unaffected.
    ///
    function _getRevokableRoles(
        uint256 resource,
        address account
    ) internal view virtual override returns (uint256) {
        if (
            resource != ROOT_RESOURCE &&
            ownerOf(_constructTokenId(resource, _entry(resource))) == address(0)
        ) {
            return 0; // available or reserved
        }
        return super._getRevokableRoles(resource, account);
    }

    /// @dev Zeroes version bits in `anyId` to return the canonical storage entry for the name.
    function _entry(uint256 anyId) internal view returns (Entry storage) {
        return _entries[LibLabel.withVersion(anyId, 0)];
    }

    /// @dev Assert token is not expired and caller has necessary roles.
    function _checkExpiryAndTokenRoles(
        uint256 anyId,
        uint256 roleBitmap
    ) internal view returns (uint256 tokenId, Entry storage entry) {
        entry = _entry(anyId);
        tokenId = _constructTokenId(anyId, entry);
        if (_isExpired(entry.expiry)) {
            revert LabelExpired(tokenId);
        }
        _checkRoles(_constructResource(anyId, entry), roleBitmap, _msgSender());
    }

    /// @dev Internal logic for expired status.
    function _isExpired(uint64 expiry) internal view returns (bool) {
        return block.timestamp >= expiry;
    }

    /// @dev Create `resource` from parts.
    ///      Returns next resource if expired.
    function _constructResource(
        uint256 anyId,
        Entry storage entry
    ) internal view returns (uint256) {
        return LibLabel.withVersion(anyId, entry.eacVersionId);
    }

    /// @dev Create `tokenId` from parts.
    function _constructTokenId(uint256 anyId, Entry storage entry) internal view returns (uint256) {
        return LibLabel.withVersion(anyId, entry.tokenVersionId);
    }

    /// @dev Create `Status` from parts.
    function _constructStatus(uint64 expiry, address owner) internal view returns (Status) {
        if (_isExpired(expiry)) {
            return Status.AVAILABLE;
        } else if (owner == address(0)) {
            return Status.RESERVED;
        } else {
            return Status.REGISTERED;
        }
    }
}
