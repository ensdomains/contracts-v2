// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";

import {WrapperReceiver} from "./WrapperReceiver.sol";

contract LockedMigrationController is WrapperReceiver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    IPermissionedRegistry public immutable ETH_REGISTRY;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(
        IPermissionedRegistry ethRegistry,
        INameWrapper nameWrapper,
        VerifiableFactory verifiableFactory,
        address wrapperRegistryImpl
    ) WrapperReceiver(nameWrapper, verifiableFactory, wrapperRegistryImpl) {
        ETH_REGISTRY = ethRegistry;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    function _inject(
        string memory label,
        address owner,
        IRegistry subregistry,
        address resolver,
        uint256 roleBitmap,
        uint64 expiry
    ) internal override returns (uint256 tokenId) {
        return ETH_REGISTRY.register(label, owner, subregistry, resolver, roleBitmap, expiry);
    }

    function _parentNode() internal pure override returns (bytes32) {
        return NameCoder.ETH_NODE;
    }
}
