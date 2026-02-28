// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {V2Fixture, EACBaseRolesLib} from "./V2Fixture.sol";

contract V2FixtureTest is V2Fixture {
    address user = makeAddr("user");

    function setUp() external {
        deployV2Fixture();
    }

    function test_deployUserRegistry(uint256 salt) external {
        deployUserRegistry(user, EACBaseRolesLib.ALL_ROLES, salt);
    }

    function test_computeVerifiableFactoryAddress(uint256 salt) external {
        assertEq(
            address(deployUserRegistry(user, 0, salt)),
            _computeVerifiableFactoryAddress(address(this), salt)
        );
    }
}
