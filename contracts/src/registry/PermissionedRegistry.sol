// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {IEnhancedAccessControl} from "../access-control/interfaces/IEnhancedAccessControl.sol";
import {EACBaseRolesLib} from "../access-control/libraries/EACBaseRolesLib.sol";
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

/// @notice A tokenized registry with permissions that apply to every subdomain or a specific subdomain.
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
///       |    w/owner=0     | +ROLE_RESERVE_REGISTRAR |
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
        uint32 eacVersionId;
        uint32 tokenVersionId;
        IRegistry subregistry;
        uint64 expiry;
        address resolver;
    }

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    mapping(uint256 storageId => Entry entry) internal _entries;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

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
            interfaceId == type(IRegistry).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IStandardRegistry
    function setSubregistry(uint256 anyId, IRegistry registry) public override {
        (uint256 tokenId, Entry storage entry) = _checkExpiryAndTokenRoles(
            anyId,
            RegistryRolesLib.ROLE_SET_SUBREGISTRY
        );
        entry.subregistry = registry;
        emit SubregistryUpdated(tokenId, registry, _msgSender());
    }

    /// @inheritdoc IStandardRegistry
    function setResolver(uint256 anyId, address resolver) public override {
        (uint256 tokenId, Entry storage entry) = _checkExpiryAndTokenRoles(
            anyId,
            RegistryRolesLib.ROLE_SET_RESOLVER
        );
        entry.resolver = resolver;
        emit ResolverUpdated(tokenId, resolver, _msgSender());
    }

    /// @inheritdoc IStandardRegistry
    function register(
        string memory label,
        address owner,
        IRegistry registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) public virtual override returns (uint256 tokenId) {
        NameCoder.assertLabelSize(label);
        if (_isExpired(expiry)) {
            revert CannotSetPastExpiration(expiry);
        }
        uint256 labelId = LibLabel.id(label);
        Entry storage entry = _entry(labelId);
        tokenId = _constructTokenId(labelId, entry);
        address prevOwner = super.ownerOf(tokenId);
        address sender = _msgSender();
        if (_isExpired(entry.expiry)) {
            // label is AVAILABLE
            _checkRoles(ROOT_RESOURCE, RegistryRolesLib.ROLE_REGISTRAR, sender);
        } else {
            if (prevOwner != address(0)) {
                revert NameAlreadyRegistered(label); // cannot overwrite REGISTERED
            } else if (owner == address(0)) {
                revert NameAlreadyReserved(label); // cannot reserve RESERVED
            } else if (roleBitmap != 0) {
                revert EACCannotGrantRoles(ROOT_RESOURCE, roleBitmap, sender);
            }
            // label is RESERVED
            _checkRoles(ROOT_RESOURCE, RegistryRolesLib.ROLE_RESERVE_REGISTRAR, sender);
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
        // emit NameRegistered before mint so we can determine this is a registry (in an indexer)
        if (owner == address(0)) {
            emit NameReserved(tokenId, bytes32(labelId), label, expiry, sender);
        } else {
            emit NameRegistered(tokenId, bytes32(labelId), label, owner, expiry, sender);
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
        emit NameUnregistered(tokenId, _msgSender());
        address owner = super.ownerOf(tokenId);
        if (owner != address(0)) {
            _burn(owner, tokenId, 1);
            ++entry.eacVersionId;
            ++entry.tokenVersionId;
        }
        entry.expiry = uint64(block.timestamp);
    }

    /// @inheritdoc IStandardRegistry
    /// @dev Requires an `REGISTERED | RESERVED` and `ROLE_RENEW`.
    function renew(uint256 anyId, uint64 newExpiry) public override {
        (uint256 tokenId, Entry storage entry) = _checkExpiryAndTokenRoles(
            anyId,
            RegistryRolesLib.ROLE_RENEW
        );
        if (newExpiry < entry.expiry) {
            revert CannotReduceExpiration(entry.expiry, newExpiry);
        }
        entry.expiry = newExpiry;
        emit ExpiryUpdated(tokenId, newExpiry, _msgSender());
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
        return anyId == ROOT_RESOURCE ? ROOT_RESOURCE : _constructResource(anyId, _entry(anyId));
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

    // Enhanced access control methods adapted for token-based resources

    function roles(
        uint256 anyId,
        address account
    ) public view override(EnhancedAccessControl, IEnhancedAccessControl) returns (uint256) {
        return super.roles(getResource(anyId), account);
    }

    function roleCount(
        uint256 anyId
    ) public view override(EnhancedAccessControl, IEnhancedAccessControl) returns (uint256) {
        return super.roleCount(getResource(anyId));
    }

    function hasRoles(
        uint256 anyId,
        uint256 roleBitmap,
        address account
    ) public view override(EnhancedAccessControl, IEnhancedAccessControl) returns (bool) {
        return super.hasRoles(getResource(anyId), roleBitmap, account);
    }

    function hasAssignees(
        uint256 anyId,
        uint256 roleBitmap
    ) public view override(EnhancedAccessControl, IEnhancedAccessControl) returns (bool) {
        return super.hasAssignees(getResource(anyId), roleBitmap);
    }

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

    /**
     * @dev 

    /// @dev If `AVAILABLE` requires `ROLE_REGISTRAR` on root.
    ///      If `RESERVED` requires `ROLE_RESERVE_REGISTRAR` on root.

     * @param label The label to register.
     * @param owner The owner of the registered name or null if reserved.
     * @param registry The registry to use for the name.
     * @param resolver The resolver to set for the name.
     * @param roleBitmap The roles to grant to the owner.
     * @param expiry The expiration time of the name.
     * @return tokenId The token ID of the registered name.
     */
    function _register(
        string memory label,
        address owner,
        IRegistry registry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry,
        address sender
    ) internal virtual returns (uint256 tokenId) {}

    /**
     * @dev Override the base registry _update function to transfer the roles to the new owner when the token is transferred.
     */
    function _update(
        address from,
        address to,
        uint256[] memory tokenIds,
        uint256[] memory values
    ) internal virtual override {
        bool externalTransfer = to != address(0) && from != address(0);
        if (externalTransfer) {
            // Check ROLE_CAN_TRANSFER for actual transfers only
            // Skip check for mints (from == address(0)) and burns (to == address(0))
            for (uint256 i; i < tokenIds.length; ++i) {
                if (!hasRoles(tokenIds[i], RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN, from)) {
                    revert TransferDisallowed(tokenIds[i], from);
                }
            }
        }
        super._update(from, to, tokenIds, values);
        if (externalTransfer) {
            for (uint256 i; i < tokenIds.length; ++i) {
                _transferRoles(getResource(tokenIds[i]), from, to, false);
            }
        }
    }

    /**
     * @dev Override the base registry _onRolesGranted function to regenerate the token when the roles are granted.
     */
    function _onRolesGranted(
        uint256 resource,
        address /*account*/,
        uint256 /*oldRoles*/,
        uint256 /*newRoles*/,
        uint256 /*roleBitmap*/
    ) internal virtual override {
        _regenerateToken(resource);
    }

    /**
     * @dev Override the base registry _onRolesRevoked function to regenerate the token when the roles are revoked.
     */
    function _onRolesRevoked(
        uint256 resource,
        address /*account*/,
        uint256 /*oldRoles*/,
        uint256 /*newRoles*/,
        uint256 /*roleBitmap*/
    ) internal virtual override {
        _regenerateToken(resource);
    }

    /// @dev Bump `tokenVersionId` via burn+mint if token is not expired.
    function _regenerateToken(uint256 anyId) internal {
        Entry storage entry = _entry(anyId);
        if (!_isExpired(entry.expiry)) {
            uint256 tokenId = _constructTokenId(anyId, entry);
            address owner = super.ownerOf(tokenId); // skip expiry check
            if (owner != address(0)) {
                _burn(owner, tokenId, 1);
                ++entry.tokenVersionId;
                uint256 newTokenId = _constructTokenId(tokenId, entry);
                _mint(owner, newTokenId, 1, "");
                emit TokenRegenerated(tokenId, newTokenId); // resource is unchanged
            }
        }
    }

    /**
     * @dev Override to prevent admin roles from being granted in the registry.
     *
     * In the registry context, admin roles are only assigned during name registration
     * to maintain controlled permission management. This ensures that role delegation
     * follows the intended security model where admin privileges are granted at
     * registration time and cannot be arbitrarily granted afterward.
     *
     * @param resource The resource to get settable roles for.
     * @param account The account to get settable roles for.
     * @return The settable roles (regular roles only, not admin roles).
     */
    function _getSettableRoles(
        uint256 resource,
        address account
    ) internal view virtual override returns (uint256) {
        uint256 allRoles = super.roles(resource, account) | super.roles(ROOT_RESOURCE, account);
        uint256 adminRoleBitmap = allRoles & EACBaseRolesLib.ADMIN_ROLES;
        return adminRoleBitmap >> 128;
    }

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
            revert NameExpired(tokenId);
        }
        _checkRoles(_constructResource(anyId, entry), roleBitmap, _msgSender());
    }

    /// @dev Internal logic for expired status.
    ///      Only use of `block.timestamp`.
    function _isExpired(uint64 expiry) internal view returns (bool) {
        return block.timestamp >= expiry;
    }

    /// @dev Create `resource` from parts.
    ///      Returns next resource if expired.
    function _constructResource(
        uint256 anyId,
        Entry storage entry
    ) internal view returns (uint256) {
        return
            LibLabel.withVersion(
                anyId,
                _isExpired(entry.expiry) ? entry.eacVersionId + 1 : entry.eacVersionId
            );
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
