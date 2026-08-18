// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

// NOTE: most of these tests are covered by LibRegistry.t.sol
contract UniversalHelperTest is V2Fixture {
    function setUp() external {
        deployV2Fixture();
    }

    function test_findOwner() external {
        assertEq(universalHelper.findOwner(NameCoder.encode("")), address(0));
        assertEq(universalHelper.findOwner(NameCoder.encode("eth")), address(this));

        ethRegistry.register(
            "test",
            address(1),
            IRegistry(address(0)),
            address(0),
            0,
            type(uint64).max
        );
        assertEq(universalHelper.findOwner(NameCoder.encode("test.eth")), address(1));
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
}
