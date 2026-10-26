// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {
    OwnableUpgradeable
} from "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";

import {AbstractWrapperReceiver} from "./AbstractWrapperReceiver.sol";
import {LockedWrapperReceiver} from "./LockedWrapperReceiver.sol";

/// @notice Migration controller for handling locked .eth names.
///
/// Assumes premigration has `RESERVED` existing ENSv1 names.
/// Requires `ROLE_REGISTER_RESERVED` on .eth registry to perform migration.
///
contract LockedMigrationController is
    LockedWrapperReceiver,
    UUPSUpgradeable,
    OwnableUpgradeable,
    IProxyAuthorization
{
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 .eth `PermissionedRegistry` where migrated names are registered.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param nameWrapper The ENSv1 `NameWrapper` contract.
    /// @param graveyard The ENSv1 `BaseRegistrar` token graveyard.
    /// @param ethRegistry The ENSv2 .eth `PermissionedRegistry` where migrated names are registered.
    /// @param verifiableFactory The shared factory for verifiable deployments.
    /// @param wrapperRegistryImpl The `WrapperRegistry` implementation contract.
    /// @param publicResolverSet The list of `PublicResolver` contracts that require replacement.
    /// @param publicResolver The replacement `PublicResolver`.
    /// @param namer The implementation namer.
    constructor(
        INameWrapper nameWrapper,
        address graveyard,
        IPermissionedRegistry ethRegistry,
        VerifiableFactory verifiableFactory,
        address wrapperRegistryImpl,
        IAddressSet publicResolverSet,
        address publicResolver,
        address namer
    )
        LockedWrapperReceiver(
            nameWrapper,
            graveyard,
            verifiableFactory,
            wrapperRegistryImpl,
            publicResolverSet,
            publicResolver
        )
    {
        _disableInitializers();
        _transferOwnership(namer);
        ETH_REGISTRY = ethRegistry;
    }

    /// @notice Initialize the contract.
    /// @param owner_ The contract owner.
    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
    }

    /// @inheritdoc AbstractWrapperReceiver
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(UUPSUpgradeable).interfaceId ||
            interfaceId == type(IProxyAuthorization).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Declares this implementation as an eligible verifiable proxy upgrade target.
    /// @param {previousImplementation} Ignored.
    /// @return allowed Always `false` as this is the first implementation.
    function canUpgradeFrom(
        address /* previousImplementation */
    )
        external
        pure
        virtual
        override
        returns (bool allowed)
    {}

    /// @notice Returns the DNS-encoded name for "eth".
    function getWrappedNode() public pure override returns (bytes32) {
        return NameCoder.ETH_NODE;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Register `RESERVED` .eth token.
    function _inject(
        string memory label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint256 roleBitmap,
        uint64 /*expiry*/
    )
        internal
        override
        returns (uint256 tokenId)
    {
        return
            ETH_REGISTRY.register(
                label,
                owner,
                subregistry,
                resolver,
                roleBitmap,
                0 // use reserved expiry
            ); // reverts if not RESERVED
    }

    /// @dev Restrict UUPS upgrades to owner.
    /// @param {newImplementation} Ignored.
    function _authorizeUpgrade(
        address /*newImplementation*/
    )
        internal
        view
        override
        onlyOwner
    {}

    /// @inheritdoc LockedWrapperReceiver
    function _getRegistry() internal view override returns (IRegistry) {
        return ETH_REGISTRY;
    }
}
