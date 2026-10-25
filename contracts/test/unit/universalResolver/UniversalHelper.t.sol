// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {BytesUtils} from "@ens/contracts/utils/BytesUtils.sol";

import {
    IEACGrantInitializable,
    Grant
} from "~src/access-control/interfaces/IEACGrantInitializable.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {WrapperRegistryLib} from "~src/registry/libraries/WrapperRegistryLib.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {PermissionedRegistry} from "~src/registry/PermissionedRegistry.sol";
import {UserRegistry} from "~src/registry/UserRegistry.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {UniversalHelper} from "~src/universalResolver/UniversalHelper.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract UniversalHelperTest is V2Fixture {
    address lockedMigrationController = makeAddr("LockedMigrationController");
    address userRegistryImpl;
    UniversalHelper universalHelper;

    function setUp() external {
        deployV2Fixture();

        userRegistryImpl = address(
            new UserRegistry(labelStore, boxedRenderer, address(contractNamer))
        );

        trustedRegistrySet.approve(userRegistryImpl, true);

        universalHelper = new UniversalHelper(
            rootRegistry,
            verifiableFactory,
            trustedRegistrySet,
            lockedMigrationController,
            contractNamer
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Tests covered by LibResolution.t.sol
    ////////////////////////////////////////////////////////////////////////

    function test_findExactOwner() external {
        assertEq(universalHelper.findExactOwner(NameCoder.encode("")), address(0));
        assertEq(universalHelper.findExactOwner(NameCoder.encode("eth")), address(this));
        ethRegistry.register(
            "test",
            address(1),
            IRegistry(address(0)),
            address(0),
            0,
            type(uint64).max
        );
        assertEq(universalHelper.findExactOwner(NameCoder.encode("test.eth")), address(1));
        assertEq(universalHelper.findExactOwner(NameCoder.encode("sub.test.eth")), address(0));
    }

    function test_findNearestOwner() external view {
        _findNearestOwner("");
        _findNearestOwner("eth");
        _findNearestOwner("test.eth");
        _findNearestOwner("sub.test.eth");
    }

    function _findNearestOwner(string memory ens) internal view {
        bytes memory name = NameCoder.encode(ens);
        (address owner, uint256 offset) = universalHelper.findNearestOwner(name);
        assertEq(
            owner,
            universalHelper.findExactOwner(BytesUtils.substring(name, offset, name.length - offset))
        );
    }

    function test_findCanonicalName() external view {
        assertEq(universalHelper.findCanonicalName(rootRegistry), NameCoder.encode(""));
        assertEq(universalHelper.findCanonicalName(ethRegistry), NameCoder.encode("eth"));
    }

    function test_findCanonicalRegistry() external view {
        assertEq(
            address(universalHelper.findCanonicalRegistry(NameCoder.encode(""))),
            address(rootRegistry)
        );
        assertEq(
            address(universalHelper.findCanonicalRegistry(NameCoder.encode("eth"))),
            address(ethRegistry)
        );
    }

    function test_findNearestRegistry() external view {
        _findNearestRegistry("");
        _findNearestRegistry("eth");
        _findNearestRegistry("test.eth");
        _findNearestRegistry("sub.test.eth");
    }

    function _findNearestRegistry(string memory ens) internal view {
        bytes memory name = NameCoder.encode(ens);
        (IRegistry registry, uint256 offset) = universalHelper.findNearestRegistry(name);
        assertEq(
            address(registry),
            address(
                universalHelper.findExactRegistry(
                    BytesUtils.substring(name, offset, name.length - offset)
                )
            )
        );
    }

    function test_findExactRegistry() external view {
        assertEq(
            address(universalHelper.findExactRegistry(NameCoder.encode(""))),
            address(rootRegistry)
        );
        assertEq(
            address(universalHelper.findExactRegistry(NameCoder.encode("eth"))),
            address(ethRegistry)
        );
    }

    function test_findParentRegistry() external view {
        assertEq(address(universalHelper.findParentRegistry(NameCoder.encode(""))), address(0));
        assertEq(
            address(universalHelper.findParentRegistry(NameCoder.encode("eth"))),
            address(rootRegistry)
        );
    }

    function test_findRegistries() external view {
        IRegistry[] memory v = universalHelper.findRegistries(NameCoder.encode("eth"));
        assertEq(address(v[0]), address(ethRegistry));
        assertEq(address(v[1]), address(rootRegistry));
    }

    ////////////////////////////////////////////////////////////////////////
    // Tests covered by LockedMigrationController.t.sol
    ////////////////////////////////////////////////////////////////////////

    function test_findWrapperRegistry() external view {
        bytes memory name = NameCoder.encode("a.b.c.test.eth");
        (address addr, ) =
            WrapperRegistryLib.computeAddress(verifiableFactory, lockedMigrationController, name, 0);
        assertEq(address(universalHelper.findWrapperRegistry(name)), addr);
    }

    ////////////////////////////////////////////////////////////////////////
    // Verification Functions
    ////////////////////////////////////////////////////////////////////////

    function test_findTrustedParentRegistry_eth() external view {
        assertEq(
            address(universalHelper.findTrustedParentRegistry(NameCoder.encode("eth"))),
            address(rootRegistry)
        );
    }

    function test_findTrustedParentRegistry_testEth() external view {
        assertEq(
            address(universalHelper.findTrustedParentRegistry(NameCoder.encode("test.eth"))),
            address(ethRegistry)
        );
    }

    function test_findTrustedParentRegistry_subTestEth() external {
        string memory label = "test";
        ethRegistry.register(
            label,
            address(this),
            IRegistry(address(0)),
            address(0),
            EACBaseRolesLib.ALL_ROLES,
            type(uint64).max
        );
        bytes memory name = NameCoder.addLabel(NameCoder.ethName(label), "sub");

        assertEq(address(universalHelper.findTrustedParentRegistry(name)), address(0), "unset");

        IRegistry valid = _deployUserRegistry();
        ethRegistry.setSubregistry(LibLabel.id(label), valid);
        assertEq(address(universalHelper.findTrustedParentRegistry(name)), address(valid), "valid");

        ethRegistry.setSubregistry(LibLabel.id(label), IRegistry(makeAddr("invalid")));
        assertEq(address(universalHelper.findTrustedParentRegistry(name)), address(0), "invalid");
    }

    function test_isTrustedRegistry() external {
        assertTrue(universalHelper.isTrustedRegistry(rootRegistry), "root");
        assertTrue(universalHelper.isTrustedRegistry(ethRegistry), "eth");

        PermissionedRegistry permAdhoc =
            new PermissionedRegistry(labelStore, address(this), EACBaseRolesLib.ALL_ROLES);
        assertFalse(universalHelper.isTrustedRegistry(permAdhoc), "perm:adhoc");

        assertFalse(
            universalHelper.isTrustedRegistry(
                IRegistry(verifiableFactory.deployProxy(address(permAdhoc), 0, ""))
            ),
            "perm:verified"
        );

        UserRegistry userAdhoc = new UserRegistry(labelStore, boxedRenderer, address(contractNamer));
        assertFalse(universalHelper.isTrustedRegistry(userAdhoc), "user:adhoc");

        assertTrue(universalHelper.isTrustedRegistry(_deployUserRegistry()), "user:verified:before");
    }

    function test_isEmancipatedRegistry_perm() external {
        PermissionedRegistry r = new PermissionedRegistry(labelStore, address(this), 0);
        assertTrue(r.isEmancipated(), "self");
        assertFalse(universalHelper.isEmancipatedRegistry(r), "helper");
    }

    function test_isEmancipatedRegistry_user() external {
        UserRegistry r = _deployUserRegistry();
        assertFalse(r.isEmancipated(), "self:before");
        assertFalse(universalHelper.isEmancipatedRegistry(r), "helper:before");

        r.revokeRootRoles(RegistryRolesLib.UNEMANCIPATED_ROLE_BITMAP, address(this));
        assertTrue(r.isEmancipated(), "self");
        assertTrue(universalHelper.isEmancipatedRegistry(r), "helper");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _deployUserRegistry() internal returns (UserRegistry) {
        Grant[] memory grants = new Grant[](1);
        grants[0] = Grant(address(this), EACBaseRolesLib.ALL_ROLES);
        return
            UserRegistry(
                verifiableFactory.deployProxy(
                    userRegistryImpl,
                    block.number,
                    abi.encodeCall(IEACGrantInitializable.initialize, (grants))
                )
            );
    }
}
