// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {IWrapperRegistry} from "../registry/interfaces/IWrapperRegistry.sol";
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

    /// @notice Find the parent registry iff every ancestor is trusted.
    /// @param name The DNS-encoded name.
    /// @return parent The parent registry or null if any ancestor was not trusted.
    function findTrustedParentRegistry(bytes calldata name)
        external
        view
        returns (IRegistry parent)
    {
        (bytes32 labelHash, uint256 next) = NameCoder.readLabel(name, 0);
        if (labelHash != bytes32(0)) {
            parent = LibResolution.findQualifiedRegistry(
                address(this),
                this.isTrustedRegistry.selector,
                ROOT_REGISTRY,
                name,
                next
            );
            parent = _ensureWrapperRegistry(parent, name);
        }
    }

    /// @notice Find the parent registry iff every ancestor is emancipated.
    /// @param name The DNS-encoded name.
    /// @return parent The parent registry or null if any ancestor was not emancipated.
    function findEmancipatedParentRegistry(bytes calldata name)
        external
        view
        returns (IRegistry parent)
    {
        (bytes32 labelHash, uint256 next) = NameCoder.readLabel(name, 0);
        if (labelHash != bytes32(0)) {
            parent = LibResolution.findQualifiedRegistry(
                address(this),
                this.isEmancipatedRegistry.selector,
                ROOT_REGISTRY,
                name,
                next
            );
            parent = _ensureWrapperRegistry(parent, name);
        }
    }

    /// @notice Compute the wrapped registry address for `name`.
    /// @param name The DNS-encoded name.
    /// @return The prediect
    function computeWrapperRegistry(bytes calldata name) public view returns (IRegistry) {
        return
            IRegistry(
                WrapperRegistryLib.computeAddress(VERIFIABLE_FACTORY, ETH_WRAPPER_DEPLOYER, name)
            );
    }

    /// @notice Determine if registry is trusted.  Does not check ancestory.
    /// @param registry The registry to check.
    /// @return `true` if registry is trusted.
    function isTrustedRegistry(IRegistry registry) public view returns (bool) {
        if (address(registry) == address(0)) {
            return false;
        }
        if (TRUSTED_REGISTRY_SET.includes(address(registry))) {
            return true;
        }
        try VERIFIABLE_FACTORY.verifyContract(address(registry)) returns (address impl) {
            return TRUSTED_REGISTRY_SET.includes(impl);
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

    /// @dev If the (verified) registry is a `WrapperRegistry`, ensure it was deployed via migration.
    function _ensureWrapperRegistry(IRegistry registry, bytes calldata name)
        internal
        view
        returns (IRegistry)
    {
        if (
            ERC165Checker.supportsERC165InterfaceUnchecked(
                address(registry),
                type(IWrapperRegistry).interfaceId
            ) &&
            address(computeWrapperRegistry(name)) != address(registry)
        ) {
            return IRegistry(address(0));
        }
        return registry;
    }
}
