// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {V1Fixture} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract FindResolverTest is V1Fixture, V2Fixture {
    function setUp() external {
        deployV1Fixture();
        deployV2Fixture();
    }

    function test_findResolver(uint256) external {
        // TODO
    }
}
