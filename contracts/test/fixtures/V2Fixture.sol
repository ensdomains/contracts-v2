// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {GatewayProvider} from "@ens/contracts/ccipRead/GatewayProvider.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {BaseUriRegistryMetadata} from "~src/registry/BaseUriRegistryMetadata.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {UniversalResolverV2} from "~src/universalResolver/UniversalResolverV2.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

/// @dev Reusable testing fixture for ENSv2 with a basic ".eth" deployment.
contract V2Fixture {
    VerifiableFactory verifiableFactory;
    MockHCAFactoryBasic hcaFactory;
    BaseUriRegistryMetadata metadata;
    PermissionedRegistry rootRegistry;
    PermissionedRegistry ethRegistry;
    GatewayProvider batchGatewayProvider;
    UniversalResolverV2 universalResolver;

    function deployV2Fixture() public {
        verifiableFactory = new VerifiableFactory();
        hcaFactory = new MockHCAFactoryBasic();
        metadata = new BaseUriRegistryMetadata(hcaFactory);
        rootRegistry = new PermissionedRegistry(
            hcaFactory,
            metadata,
            address(this),
            EACBaseRolesLib.ALL_ROLES
        );
        ethRegistry = new PermissionedRegistry(
            hcaFactory,
            metadata,
            address(this),
            EACBaseRolesLib.ALL_ROLES
        );
        rootRegistry.register(
            "eth",
            address(this),
            ethRegistry,
            address(0),
            EACBaseRolesLib.ALL_ROLES,
            type(uint64).max
        );
        batchGatewayProvider = new GatewayProvider(address(this), new string[](0));
        universalResolver = new UniversalResolverV2(rootRegistry, batchGatewayProvider);
    }

    function findResolverV2(bytes memory name) public view returns (address resolver) {
        (resolver, , ) = universalResolver.findResolver(name);
    }
}
