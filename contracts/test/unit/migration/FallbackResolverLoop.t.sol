// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IUniversalResolver} from "@ens/contracts/universalResolver/IUniversalResolver.sol";
import {ResolverCaller} from "@ens/contracts/universalResolver/ResolverCaller.sol";

import {MigrationControllerFixture} from "~test/fixtures/MigrationControllerFixture.sol";

contract FallbackResolverLoopTest is MigrationControllerFixture {
    function setUp() external {
        deployMigrationControllerFixture();
    }

    function test_trivialLoopTerminates() external {
        (bytes memory name, ) = registerUnwrapped(testLabel);
        assertEq(registryV1.resolver(NameCoder.namehash(name, 0)), address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalResolver.ResolverError.selector,
                abi.encodeWithSelector(ResolverCaller.UnreachableName.selector, name)
            )
        );
        universalResolver.resolve(name, "");
    }
}
