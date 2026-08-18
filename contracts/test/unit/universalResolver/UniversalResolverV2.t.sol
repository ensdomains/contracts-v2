// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IUniversalResolver} from "@ens/contracts/universalResolver/IUniversalResolver.sol";

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IUniversalResolverV2} from "~src/universalResolver/interfaces/IUniversalResolverV2.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract UniversalResolverV2Test is V2Fixture {
    address resolverAddress = makeAddr("resolver");

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

    function test_isENSV2() external view {
        assertTrue(universalResolver.isENSv2());
    }

    function test_findResolver_1LD() external {
        rootRegistry.register(
            "test",
            address(0),
            IRegistry(address(0)),
            resolverAddress,
            0,
            type(uint64).max
        );
        (address resolver, , ) = universalResolver.findResolver(NameCoder.encode("test"));
        assertEq(resolver, resolverAddress);
    }

    function test_findResolver_test_eth() external {
        ethRegistry.register(
            "test",
            address(0),
            IRegistry(address(0)),
            resolverAddress,
            0,
            type(uint64).max
        );
        (address resolver, , ) = universalResolver.findResolver(NameCoder.encode("test.eth"));
        assertEq(resolver, resolverAddress);
    }
}
