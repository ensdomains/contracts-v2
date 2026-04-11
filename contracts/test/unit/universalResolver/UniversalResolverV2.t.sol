// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IUniversalResolver} from "@ens/contracts/universalResolver/IUniversalResolver.sol";

import {
    IUniversalResolverV2,
    IRegistry
} from "~src/universalResolver/interfaces/IUniversalResolverV2.sol";

import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

// NOTE: most of these tests are covered by LibRegistry.t.sol

contract UniversalResolverV2Test is V2Fixture {
    function setUp() external {
        deployV2Fixture();
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(
                address(universalResolver),
                type(IUniversalResolver).interfaceId
            ),
            "IUniversalResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(universalResolver),
                type(IUniversalResolverV2).interfaceId
            ),
            "IUniversalResolverV2"
        );
    }

    function test_findCanonicalName() external view {
        assertEq(universalResolver.findCanonicalName(rootRegistry), NameCoder.encode(""));
        assertEq(universalResolver.findCanonicalName(ethRegistry), NameCoder.encode("eth"));
    }

    function test_findCanonicalRegistry() external view {
        assertEq(
            address(universalResolver.findCanonicalRegistry(NameCoder.encode(""))),
            address(rootRegistry)
        );
        assertEq(
            address(universalResolver.findCanonicalRegistry(NameCoder.encode("eth"))),
            address(ethRegistry)
        );
    }

    function test_findExactRegistry() external view {
        assertEq(
            address(universalResolver.findExactRegistry(NameCoder.encode(""))),
            address(rootRegistry)
        );
        assertEq(
            address(universalResolver.findExactRegistry(NameCoder.encode("eth"))),
            address(ethRegistry)
        );
    }

    function test_findParentRegistry() external view {
        assertEq(address(universalResolver.findParentRegistry(NameCoder.encode(""))), address(0));
        assertEq(
            address(universalResolver.findParentRegistry(NameCoder.encode("eth"))),
            address(rootRegistry)
        );
    }

    function test_findRegistries() external view {
        IRegistry[] memory v = universalResolver.findRegistries(NameCoder.encode("eth"));
        assertEq(address(v[0]), address(ethRegistry));
        assertEq(address(v[1]), address(rootRegistry));
    }
}
