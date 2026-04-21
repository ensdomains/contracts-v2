// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";

import {LockedWrapperReceiver} from "./LockedWrapperReceiver.sol";

/// @notice Migration controller for handling locked .eth names.
///
/// Assumes premigration has `RESERVED` existing ENSv1 names.
/// Requires `ROLE_REGISTER_RESERVED` on .eth registry to perform migration.
///
contract LockedMigrationController is LockedWrapperReceiver {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 .eth `PermissionedRegistry` where migrated names are registered.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes LockedMigrationController.
    /// @param nameWrapper The ENSv1 `NameWrapper` contract.
    /// @param ethRegistry The ENSv2 .eth `PermissionedRegistry` where migrated names are registered.
    /// @param verifiableFactory The shared factory for verifiable deployments.
    /// @param wrapperRegistryImpl The `WrapperRegistry` implementation contract.
    constructor(
        INameWrapper nameWrapper,
        IPermissionedRegistry ethRegistry,
        VerifiableFactory verifiableFactory,
        address wrapperRegistryImpl
    )
        LockedWrapperReceiver(nameWrapper, verifiableFactory, wrapperRegistryImpl)
    {
        ETH_REGISTRY = ethRegistry;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

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

    /// @inheritdoc LockedWrapperReceiver
    function _getRegistry() internal view override returns (IRegistry) {
        return ETH_REGISTRY;
    }
}
