// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {IWrapperRegistry} from "../registry/interfaces/IWrapperRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";
import {WrapperRegistryLib} from "../registry/libraries/WrapperRegistryLib.sol";
import {IContractNamer} from "../reverse-registrar/interfaces/IContractNamer.sol";
import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";
import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";

import {LibResolution} from "./libraries/LibResolution.sol";

/// @notice Collection of non-essential ENSv2 functions.
contract UniversalHelper is DelegatedContractNamer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice ENSv2 root registry.
    IPermissionedRegistry public immutable ROOT_REGISTRY;

    /// @notice The shared factory for verifiable deployments.
    IVerifiableFactory public immutable VERIFIABLE_FACTORY;

    /// @notice Set of trusted registry contracts and implementations.
    IAddressSet public immutable TRUSTED_REGISTRY_SET;

    /// @notice Address of "eth" deployer for `WrapperRegistry`.
    address public immutable ETH_WRAPPER_DEPLOYER;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param rootRegistry The root registry.
    /// @param verifiableFactory The VerifiableFactory.
    /// @param trustedRegistrySet Set of trusted registry contracts and implementations.
    /// @param ethWrapperDeployer Address of "eth" deployer for `WrapperRegistry`.
    /// @param contractNamer Delegated contract namer.
    constructor(
        IPermissionedRegistry rootRegistry,
        IVerifiableFactory verifiableFactory,
        IAddressSet trustedRegistrySet,
        address ethWrapperDeployer,
        IContractNamer contractNamer
    )
        DelegatedContractNamer(contractNamer)
    {
        ROOT_REGISTRY = rootRegistry;
        VERIFIABLE_FACTORY = verifiableFactory;
        TRUSTED_REGISTRY_SET = trustedRegistrySet;
        ETH_WRAPPER_DEPLOYER = ethWrapperDeployer;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Find the exact owner for `name`.
    /// @param name The DNS-encoded name.
    /// @return The owner address or null if unowned or not found.
    function findExactOwner(bytes calldata name) external view returns (address) {
        return LibResolution.findExactOwner(ROOT_REGISTRY, name, 0);
    }

    /// @notice Find the nearest owner for `name`.
    /// @param name The DNS-encoded name.
    /// @return owner The owner address or null if unowned or not found.
    /// @return offset The offset into `name` such that `findExactOwner(name[offset:]) == owner`.
    function findNearestOwner(bytes calldata name)
        external
        view
        returns (address owner, uint256 offset)
    {
        return LibResolution.findNearestOwner(ROOT_REGISTRY, name, 0);
    }

    /// @notice Construct the canonical name for `registry`.
    /// @param registry The registry to name.
    /// @return The DNS-encoded name or empty if not canonical.
    function findCanonicalName(IRegistry registry) external view returns (bytes memory) {
        return LibResolution.findCanonicalName(ROOT_REGISTRY, registry);
    }

    /// @notice Find the canonical registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The canonical registry or null if not canonical.
    function findCanonicalRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibResolution.findCanonicalRegistry(ROOT_REGISTRY, name);
    }

    /// @notice Find the exact registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The registry or null if not found.
    function findExactRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibResolution.findExactRegistry(ROOT_REGISTRY, name, 0);
    }

    /// @notice Find the nearest registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return registry The nearest registry or null if not found.
    /// @return offset The offset into `name` such that `findExactRegistry(name[offset:]) == registry`.
    function findNearestRegistry(bytes calldata name)
        external
        view
        returns (IRegistry registry, uint256 offset)
    {
        return LibResolution.findNearestRegistry(ROOT_REGISTRY, name, 0);
    }

    /// @notice Find the parent registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The parent registry or null if not found.
    function findParentRegistry(bytes calldata name) external view returns (IRegistry) {
        return LibResolution.findParentRegistry(ROOT_REGISTRY, name, 0);
    }

    /// @notice Find all registries in the ancestry of `name`.
    /// * `findRegistries("") = [<root>]`
    /// * `findRegistries("eth") = [<eth>, <root>]`
    /// * `findRegistries("nick.eth") = [<nick>, <eth>, <root>]`
    /// * `findRegistries("sub.nick.eth") = [null, <nick>, <eth>, <root>]`
    ///
    /// @param name The DNS-encoded name.
    /// @return Array of registries in label-order.
    function findRegistries(bytes calldata name) external view returns (IRegistry[] memory) {
        return LibResolution.findRegistries(ROOT_REGISTRY, name, 0);
    }

    /// @notice Find the exact registry iff every ancestor is trusted.
    /// @param name The DNS-encoded name.
    /// @return The parent registry or null if any ancestor was not trusted.
    function findTrustedRegistry(bytes calldata name) external view returns (IPermissionedRegistry) {
        return _findQualifiedRegistry(isTrustedRegistry, name, 0);
    }

    /// @notice Find the exact registry iff every ancestor is emancipated.
    /// @param name The DNS-encoded name.
    /// @return The parent registry or null if any ancestor was not emancipated.
    function findEmancipatedRegistry(bytes calldata name)
        external
        view
        returns (IPermissionedRegistry)
    {
        return _findQualifiedRegistry(isEmancipatedRegistry, name, 0);
    }

    /// @notice Determine if every ancestor is emancipated and the token permits safe transfer.
    /// @param name The DNS-encoded name.
    /// @return parent The parent registry or null if any ancestor was not emancipated.
    /// @return tokenId The token ID or null if not emancipated.
    /// @return owner The token owner or null if doesn't exist.
    /// @return canTransfer `true` if the token can be transferred.
    function findEmancipatedToken(bytes calldata name)
        external
        view
        returns (IPermissionedRegistry parent, uint256 tokenId, address owner, bool canTransfer)
    {
        (bytes32 labelHash, uint256 next) = NameCoder.readLabel(name, 0);
        if (labelHash != bytes32(0)) {
            parent = _findQualifiedRegistry(isEmancipatedRegistry, name, next);
            if (address(parent) != address(0)) {
                tokenId = parent.getTokenId(uint256(labelHash));
                owner = parent.ownerOf(tokenId);
                if (owner != address(0)) {
                    canTransfer = parent.hasRoles(
                        tokenId,
                        RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN,
                        owner
                    );
                    if (
                        !parent.isOnlyAssignee(
                            tokenId,
                            RegistryRolesLib.UNEMANCIPATED_ROLE_BITMAP,  /// see: PermissionedRegistry._update()
                            owner
                        )
                    ) {
                        delete tokenId;
                    }
                }
            }
        }
    }

    /// @notice Find the expected wrapped registry for `name`.
    /// @param name The DNS-encoded name.
    /// @return The expected wrapper registry (may not exist).
    function findWrapperRegistry(bytes calldata name) external view returns (IWrapperRegistry) {
        (address addr, ) =
            WrapperRegistryLib.computeAddress(VERIFIABLE_FACTORY, ETH_WRAPPER_DEPLOYER, name, 0);
        return IWrapperRegistry(addr);
    }

    /// @notice Determine if registry implementation is trusted.  Does not check ancestory.
    /// @param registry The registry to check.
    /// @return `true` if registry is trusted.
    function isTrustedRegistry(IRegistry registry) public view returns (bool) {
        if (address(registry) == address(0)) {
            return false;
        }
        if (TRUSTED_REGISTRY_SET.includes(address(registry))) {
            return true; // trusted deployment
        }
        try VERIFIABLE_FACTORY.verifyContract(address(registry)) returns (address impl) {
            return TRUSTED_REGISTRY_SET.includes(impl); // trusted implementation
        } catch {
            return false;
        }
    }

    /// @notice Determine if registry is emancipated.  Does not check ancestory.
    /// @param registry The registry to check.
    /// @return `true` if registry is emancipated.
    function isEmancipatedRegistry(IRegistry registry) public view returns (bool) {
        return
            isTrustedRegistry(registry) && IPermissionedRegistry(address(registry)).isEmancipated();
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Find the registry iff every ancestor is qualified without checking the nearest wrapper.
    ///      Assumes root registry is qualified.
    /// @param predicate Function for testing if a registry is qualified.
    /// @param name The DNS-encoded name.
    /// @param offset The offset into `name` to start qualifying.
    /// @return registry The registry or null if any ancestor was not qualified.
    function _findQualifiedRegistry(
        function(IRegistry) view returns(bool) predicate,
        bytes memory name,
        uint256 offset
    )
        internal
        view
        returns (IPermissionedRegistry registry)
    {
        uint256 wrapperOffset;
        IRegistry nearestWrapper;
        (registry, nearestWrapper, wrapperOffset) = _findQualifiedRegistryInner(
            predicate,
            name,
            offset
        );
        if (address(nearestWrapper) != address(0)) {
            (address addr, ) =
                WrapperRegistryLib.computeAddress(
                    VERIFIABLE_FACTORY,
                    ETH_WRAPPER_DEPLOYER,
                    name,
                    wrapperOffset
                );
            if (address(nearestWrapper) != address(addr)) {
                delete registry;
            }
        }
    }

    /// @dev Recursive function for finding the qualified registry.
    function _findQualifiedRegistryInner(
        function(IRegistry) view returns(bool) predicate,
        bytes memory name,
        uint256 offset
    )
        internal
        view
        returns (IPermissionedRegistry registry, IRegistry nearestWrapper, uint256 wrapperOffset)
    {
        (string memory label, uint256 next) = NameCoder.extractLabel(name, offset);
        if (bytes(label).length == 0) {
            registry = ROOT_REGISTRY;
        } else {
            (registry, nearestWrapper, wrapperOffset) = _findQualifiedRegistryInner(
                predicate,
                name,
                next
            );
            if (address(registry) != address(0)) {
                registry = IPermissionedRegistry(
                    address(LibResolution.getSubregistry(registry, label))
                );
                if (predicate(registry)) {
                    if (
                        ERC165Checker.supportsERC165InterfaceUnchecked(
                            address(registry),
                            type(IWrapperRegistry).interfaceId
                        )
                    ) {
                        nearestWrapper = registry; // remember
                        wrapperOffset = offset;
                    }
                } else {
                    delete registry;
                }
            }
        }
    }
}
