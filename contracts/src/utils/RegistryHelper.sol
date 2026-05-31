// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {IEnhancedAccessControl} from "../access-control/interfaces/IEnhancedAccessControl.sol";
import {LibRegistry} from "../universalResolver/libraries/LibRegistry.sol";

import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {IOwnedRegistry} from "../registry/interfaces/IOwnedRegistry.sol";
import {ITemporalRegistry} from "../registry/interfaces/ITemporalRegistry.sol";
import {ITokenizedRegistry} from "../registry/interfaces/ITokenizedRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";

/// @notice Immutable read-only convenience contract that provides functions to inspect
///         name state, ownership, verification, and emancipation status across the
///         ENSv2 registry hierarchy.
contract RegistryHelper {
    uint256 private constant ROOT_RESOURCE = 0;

    IRegistry public immutable ROOT_REGISTRY;
    IRegistry public immutable ETH_REGISTRY;
    IVerifiableFactory public immutable VERIFIABLE_FACTORY;
    address public immutable USER_REGISTRY_IMPL;
    address public immutable WRAPPER_REGISTRY_IMPL;

    /// @dev Roles whose presence on ROOT_RESOURCE endangers name owners.
    ///      Two categories:
    ///      - Per-token roles (SET_RESOLVER, SET_SUBREGISTRY, UNREGISTER and their admins,
    ///        plus CAN_TRANSFER_ADMIN): exercisable on any token via the hasRoles ROOT union.
    ///      - Registry-wide roles (UPGRADE, UPGRADE_ADMIN): can replace the entire
    ///        implementation via UUPS proxy, bypassing all access control.
    ///      ROLE_RENEW and ROLE_RENEW_ADMIN are excluded: RENEW can only extend expiry
    ///      (CannotReduceExpiry), and its admin can only grant/revoke that harmless capability.
    uint256 public constant DANGEROUS_ROOT_ROLES =
        RegistryRolesLib.ROLE_SET_RESOLVER |
        RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN |
        RegistryRolesLib.ROLE_SET_SUBREGISTRY |
        RegistryRolesLib.ROLE_SET_SUBREGISTRY_ADMIN |
        RegistryRolesLib.ROLE_UNREGISTER |
        RegistryRolesLib.ROLE_UNREGISTER_ADMIN |
        RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN |
        RegistryRolesLib.ROLE_UPGRADE |
        RegistryRolesLib.ROLE_UPGRADE_ADMIN;

    /// @notice Set when the name has a minted ERC-1155 token (parent supports ITokenizedRegistry and name has an owner).
    uint8 public constant FLAG_HAS_TOKEN = 1 << 0;
    /// @notice Set when the parent registry supports IOwnedRegistry and returns a nonzero owner.
    uint8 public constant FLAG_HAS_OWNER = 1 << 1;
    /// @notice Set when the parent registry supports ITemporalRegistry and returns a nonzero expiry.
    uint8 public constant FLAG_HAS_EXPIRY = 1 << 2;
    /// @notice Set when the governing parent registry is trusted (root, eth, or factory-deployed with an approved implementation).
    uint8 public constant FLAG_IS_VERIFIED = 1 << 3;
    /// @notice Set when the parent's subregistry pointer and the child's parent pointer are bidirectionally consistent.
    uint8 public constant FLAG_IS_CANONICAL = 1 << 4;
    /// @notice Set when the governing parent registry has no dangerous roles on ROOT_RESOURCE.
    uint8 public constant FLAG_IS_EMANCIPATED = 1 << 5;

    struct LabelInfo {
        /// @dev The label's own subregistry, or address(0) if none.
        IRegistry registry;
        /// @dev Resolver set on the governing parent registry for this label.
        address resolver;
        /// @dev Owner of this label, or address(0) if unowned.
        address owner;
        /// @dev The label string (e.g. "alice" for alice.eth).
        string label;
        /// @dev Token ID from ITokenizedRegistry, or 0 if not minted.
        uint256 tokenId;
        /// @dev Expiry timestamp in seconds, or 0 if no expiry.
        uint64 expiry;
        /// @dev Bitfield of FLAG_* constants describing the name's state.
        uint8 flags;
    }

    /// @param rootRegistry The root registry (trust anchor).
    /// @param ethRegistry The .eth TLD registry (trusted by endorsement).
    /// @param verifiableFactory The VerifiableFactory used to verify registry deployments.
    /// @param userRegistryImpl The approved UserRegistry implementation address.
    /// @param wrapperRegistryImpl The approved WrapperRegistry implementation address.
    constructor(
        IRegistry rootRegistry,
        IRegistry ethRegistry,
        IVerifiableFactory verifiableFactory,
        address userRegistryImpl,
        address wrapperRegistryImpl
    ) {
        ROOT_REGISTRY = rootRegistry;
        ETH_REGISTRY = ethRegistry;
        VERIFIABLE_FACTORY = verifiableFactory;
        USER_REGISTRY_IMPL = userRegistryImpl;
        WRAPPER_REGISTRY_IMPL = wrapperRegistryImpl;
    }

    ////////////////////////////////////////////////////////////////////////
    // Name-based lookups (accept DNS-encoded name)
    ////////////////////////////////////////////////////////////////////////

    /// @notice Find the owner of a name.
    /// @param name DNS-encoded name.
    /// @return owner The owner address, or address(0) if unowned or parent doesn't support IOwnedRegistry.
    function findOwner(bytes calldata name) external view returns (address owner) {
        return LibRegistry.findOwner(ROOT_REGISTRY, name, 0);
    }

    /// @notice Find the expiry of the leaf label in its immediate parent registry.
    /// @param name DNS-encoded name.
    /// @return expiry The expiry timestamp, or 0 if parent doesn't support ITemporalRegistry.
    function findExpiry(bytes calldata name) external view returns (uint64 expiry) {
        IRegistry parent = LibRegistry.findParentRegistry(ROOT_REGISTRY, name, 0);
        if (
            address(parent) != address(0) &&
            ERC165Checker.supportsInterface(address(parent), type(ITemporalRegistry).interfaceId)
        ) {
            (string memory label, ) = NameCoder.extractLabel(name, 0);
            expiry = ITemporalRegistry(address(parent)).findExpiry(label);
        }
    }

    /// @notice Find the canonical registry for a name, or address(0) if not canonical.
    /// @param name DNS-encoded name.
    function findCanonicalRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibRegistry.findCanonicalRegistry(ROOT_REGISTRY, name);
    }

    /// @notice Check whether a name's registry chain is canonical (every parent pointer
    ///         is consistent with the subregistry pointer above it).
    /// @param name DNS-encoded name.
    function isCanonical(bytes calldata name) external view returns (bool) {
        return address(LibRegistry.findCanonicalRegistry(ROOT_REGISTRY, name)) != address(0);
    }

    /// @notice Check whether every registry in a name's ancestry is trusted.
    /// @param name DNS-encoded name.
    function isVerified(bytes calldata name) external view returns (bool) {
        IRegistry[] memory registries = LibRegistry.findRegistries(ROOT_REGISTRY, name, 0);
        // Skip index 0 (leaf's own subregistry) and last (root, always trusted)
        for (uint256 i = 1; i + 1 < registries.length; i++) {
            if (!isVerified(registries[i])) return false;
        }
        return true;
    }

    /// @notice Check whether a name is emancipated: at every level of the hierarchy, the
    ///         governing registry is trusted and no dangerous role has assignees on
    ///         ROOT_RESOURCE.
    ///         This only covers on-chain governance; DNS-imported names remain subject
    ///         to off-chain reassertion via DNSSEC proofs regardless of on-chain state.
    /// @param name DNS-encoded name.
    function isEmancipated(bytes calldata name) external view returns (bool) {
        IRegistry[] memory registries = LibRegistry.findRegistries(ROOT_REGISTRY, name, 0);
        // Skip index 0 (leaf's own subregistry) and last (root, always trusted)
        for (uint256 i = 1; i + 1 < registries.length; i++) {
            if (!isVerified(registries[i])) return false;
            if (!_isRegistryEmancipated(registries[i])) return false;
        }
        return true;
    }

    ////////////////////////////////////////////////////////////////////////
    // Registry-based lookups
    ////////////////////////////////////////////////////////////////////////

    /// @notice Reconstruct the canonical DNS-encoded name for a registry by walking parent pointers.
    /// @param registry The registry to name.
    /// @return name The DNS-encoded canonical name, or empty bytes if not canonical.
    function findCanonicalName(IRegistry registry) external view returns (bytes memory name) {
        return LibRegistry.findCanonicalName(ROOT_REGISTRY, registry);
    }

    /// @notice Check whether a registry is trusted: either an infrastructure registry
    ///         (root or .eth) or deployed by the VerifiableFactory with an approved
    ///         implementation (UserRegistry or WrapperRegistry).
    /// @param registry The registry to check.
    function isVerified(IRegistry registry) public view returns (bool) {
        return registry == ROOT_REGISTRY ||
            registry == ETH_REGISTRY ||
            VERIFIABLE_FACTORY.verifyContract(address(registry), USER_REGISTRY_IMPL) ||
            VERIFIABLE_FACTORY.verifyContract(address(registry), WRAPPER_REGISTRY_IMPL);
    }

    /// @notice Check whether a registry is emancipated: verified and no dangerous role
    ///         has assignees on ROOT_RESOURCE.
    /// @param registry The registry to check.
    function isEmancipated(IRegistry registry) external view returns (bool) {
        return isVerified(registry) && _isRegistryEmancipated(registry);
    }

    ////////////////////////////////////////////////////////////////////////
    // Batch inspection
    ////////////////////////////////////////////////////////////////////////

    /// @notice Get detailed info for every label in a name's hierarchy.
    ///         For "sub.alice.eth", returns info for ["sub", "alice", "eth"].
    /// @param name DNS-encoded name.
    /// @return labels Array of LabelInfo structs, one per label, ordered leaf-first.
    function getLabels(bytes calldata name) external view returns (LabelInfo[] memory labels) {
        uint256 count = NameCoder.countLabels(name, 0);
        labels = new LabelInfo[](count);

        IRegistry[] memory registries = LibRegistry.findRegistries(ROOT_REGISTRY, name, 0);
        // registries has length count+1: [leaf_subreg, ..., eth_registry, root]
        // We iterate labels from leaf (offset 0) to the TLD

        uint256 offset = 0;
        for (uint256 i = 0; i < count; i++) {
            (string memory label, uint256 nextOffset) = NameCoder.extractLabel(name, offset);
            // The parent registry for label at index i is registries[i+1]
            // (registries[count] = root, registries[0] = leaf's own subregistry)
            IRegistry parent = registries[i + 1];

            labels[i].label = label;
            labels[i].registry = registries[i]; // the name's own subregistry

            if (address(parent) == address(0)) {
                offset = nextOffset;
                continue;
            }

            labels[i].resolver = parent.getResolver(label);

            // Expiry
            if (ERC165Checker.supportsInterface(address(parent), type(ITemporalRegistry).interfaceId)) {
                labels[i].expiry = ITemporalRegistry(address(parent)).findExpiry(label);
                if (labels[i].expiry != 0) {
                    labels[i].flags |= FLAG_HAS_EXPIRY;
                }
            }

            // Owner
            if (ERC165Checker.supportsInterface(address(parent), type(IOwnedRegistry).interfaceId)) {
                labels[i].owner = IOwnedRegistry(address(parent)).findOwner(label);
                if (labels[i].owner != address(0)) {
                    labels[i].flags |= FLAG_HAS_OWNER;
                }
            }

            // Token ID (only populate if the token was actually minted)
            if (
                labels[i].owner != address(0) &&
                ERC165Checker.supportsInterface(address(parent), type(ITokenizedRegistry).interfaceId)
            ) {
                labels[i].tokenId = ITokenizedRegistry(address(parent)).findTokenId(label);
                labels[i].flags |= FLAG_HAS_TOKEN;
            }

            bool parentVerified = isVerified(parent);

            // Verified
            if (parentVerified) {
                labels[i].flags |= FLAG_IS_VERIFIED;
            }

            // Canonical: bidirectional link check
            if (address(registries[i]) != address(0)) {
                (IRegistry childParent, string memory childLabel) = registries[i].getParent();
                if (
                    address(parent.getSubregistry(label)) == address(registries[i]) &&
                    address(childParent) == address(parent) &&
                    keccak256(bytes(childLabel)) == keccak256(bytes(label))
                ) {
                    labels[i].flags |= FLAG_IS_CANONICAL;
                }
            }

            // Emancipated: parent must be verified and no dangerous roles on ROOT_RESOURCE
            if (parentVerified && _isRegistryEmancipated(parent)) {
                labels[i].flags |= FLAG_IS_EMANCIPATED;
            }

            offset = nextOffset;
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal
    ////////////////////////////////////////////////////////////////////////

    /// @dev Check whether a registry is emancipated: no account holds any dangerous
    ///      role on ROOT_RESOURCE. Per-token roles (SET_RESOLVER, SET_SUBREGISTRY,
    ///      UNREGISTER and their admins, plus CAN_TRANSFER_ADMIN) can be exercised on
    ///      any token via the hasRoles ROOT union. Registry-wide roles (UPGRADE,
    ///      UPGRADE_ADMIN) can replace the entire implementation, bypassing all
    ///      access control.
    /// @param registry The registry to check.
    function _isRegistryEmancipated(IRegistry registry) internal view returns (bool) {
        if (!ERC165Checker.supportsInterface(address(registry), type(IEnhancedAccessControl).interfaceId)) {
            return false;
        }
        IEnhancedAccessControl eac = IEnhancedAccessControl(address(registry));
        return !eac.hasAssignees(ROOT_RESOURCE, DANGEROUS_ROOT_ROLES);
    }
}
