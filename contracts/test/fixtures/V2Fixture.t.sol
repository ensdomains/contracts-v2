// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";

import {V2Fixture, UserRegistry} from "./V2Fixture.sol";

contract V2FixtureTest is V2Fixture {
    address user = makeAddr("user");

    function setUp() external {
        deployV2Fixture();
    }

    function test_deployUserRegistry(uint256 salt) external {
        UserRegistry registry = UserRegistry(
            deployUserRegistry(user, EACBaseRolesLib.ALL_ROLES, salt)
        );
        assertTrue(registry.supportsInterface(type(IPermissionedRegistry).interfaceId));
    }

    function test_computeVerifiableFactoryAddress(uint256 salt) external {
        assertEq(
            address(deployUserRegistry(user, 0, salt)),
            _computeVerifiableFactoryAddress(address(this), salt)
        );
    }
}
