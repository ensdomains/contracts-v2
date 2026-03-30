// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {HCAContext} from "~src/hca/HCAContext.sol";
import {HCAEquivalence} from "~src/hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "~src/hca/interfaces/IHCAFactoryBasic.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract HCAContextHarness is HCAContext {
    constructor(IHCAFactoryBasic factory) HCAEquivalence(factory) {}

    function exposedMsgSender() external view returns (address) {
        return _msgSender();
    }
}

contract HCAContextTest is Test {
    MockHCAFactoryBasic factory;
    HCAContextHarness harness;

    address user = address(0x1111);
    address hca = address(0xAAAA);
    address owner = address(0xBEEF);

    function setUp() public {
        factory = new MockHCAFactoryBasic();
        harness = new HCAContextHarness(factory);
    }

    function test_constructor_sets_factory() public view {
        // HCA_FACTORY is public immutable on the base, accessible via harness
        assertEq(address(harness.HCA_FACTORY()), address(factory));
    }

    function test_msgSender_calls_HCAEquivalence() public {
        vm.prank(user);
        vm.expectCall(
            address(factory),
            abi.encodeWithSelector(factory.getAccountOwner.selector, user)
        );
        address sender = harness.exposedMsgSender();
        assertEq(sender, user);
    }
}
