// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase

import {LibLabel} from "~src/utils/LibLabel.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {MockPremigrator} from "~test/mocks/MockPremigrator.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract MockPremigratorTest is V2Fixture {
    MockPremigrator premigrator;

    string testLabel = "test";
    IRegistry testSubregistry = IRegistry(makeAddr("subregistry"));
    address testResolver = makeAddr("resolver");

    function setUp() external {
        deployV2Fixture();
        premigrator = new MockPremigrator(ethRegistry);
        ethRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RENEW,
            address(premigrator)
        );
    }

    function test_constructor() external view {
        assertEq(address(premigrator.ETH_REGISTRY()), address(ethRegistry), "ETH_REGISTRY");
    }

    function test_preMigrate_reservesAvailableName() external {
        uint64 expiry = uint64(block.timestamp + 30 days);
        premigrator.preMigrate(testLabel, expiry, testSubregistry, testResolver);

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id(testLabel));
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.RESERVED), "status");
        assertEq(state.expiry, expiry, "expiry");
        assertEq(state.latestOwner, address(0), "latestOwner");
        assertEq(
            address(ethRegistry.getSubregistry(testLabel)),
            address(testSubregistry),
            "subregistry"
        );
        assertEq(ethRegistry.getResolver(testLabel), testResolver, "resolver");
    }

    function test_preMigrate_renewsExistingReservation() external {
        uint64 expiry = uint64(block.timestamp + 30 days);
        premigrator.preMigrate(testLabel, expiry, testSubregistry, testResolver);
        uint256 tokenId = ethRegistry.getState(LibLabel.id(testLabel)).tokenId;

        uint64 newExpiry = expiry + 30 days;
        premigrator.preMigrate(testLabel, newExpiry, IRegistry(address(0)), address(0));

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id(testLabel));
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.RESERVED), "status");
        assertEq(state.expiry, newExpiry, "expiry");
        assertEq(state.tokenId, tokenId, "tokenId");

        // renewal keeps the original reservation's subregistry and resolver
        assertEq(
            address(ethRegistry.getSubregistry(testLabel)),
            address(testSubregistry),
            "subregistry"
        );
        assertEq(ethRegistry.getResolver(testLabel), testResolver, "resolver");
    }

    function test_preMigrate_keepsLaterReservation() external {
        uint64 expiry = uint64(block.timestamp + 60 days);
        premigrator.preMigrate(testLabel, expiry, testSubregistry, testResolver);

        premigrator.preMigrate(testLabel, expiry - 30 days, IRegistry(address(0)), address(0));

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id(testLabel));
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.RESERVED), "status");
        assertEq(state.expiry, expiry, "expiry");
    }

    function test_preMigrate_skipsRegisteredName() external {
        address owner = makeAddr("owner");
        uint64 expiry = uint64(block.timestamp + 30 days);
        ethRegistry.register(testLabel, owner, IRegistry(address(0)), address(0), 0, expiry);

        premigrator.preMigrate(testLabel, expiry + 30 days, testSubregistry, testResolver);

        IPermissionedRegistry.State memory state = ethRegistry.getState(LibLabel.id(testLabel));
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.REGISTERED), "status");
        assertEq(state.expiry, expiry, "expiry");
        assertEq(state.latestOwner, owner, "latestOwner");
    }
}
