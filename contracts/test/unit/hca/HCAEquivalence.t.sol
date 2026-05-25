// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {HCAEquivalence} from "~src/hca/HCAEquivalence.sol";
import {HCAFactory} from "~src/hca/HCAFactory.sol";
import {IHCAFactoryBasic} from "~src/hca/interfaces/IHCAFactoryBasic.sol";
import {IHCAInitDataParser} from "~src/hca/interfaces/IHCAInitDataParser.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract HCAEquivalenceHarness is HCAEquivalence {
    constructor(IHCAFactoryBasic factory) HCAEquivalence(factory) {}

    function exposedMsgSender() external view returns (address) {
        return _msgSenderWithHcaEquivalence();
    }
}


contract HCAEquivalenceTest is Test {
    MockHCAFactoryBasic factory;
    HCAEquivalenceHarness harness;

    address user = address(0x1111);
    address hca = address(0xAAAA);
    address owner = address(0xBEEF);

    function setUp() public {
        factory = new MockHCAFactoryBasic();
        harness = new HCAEquivalenceHarness(IHCAFactoryBasic(address(factory)));
    }

    function test_constructor_sets_factory() public view {
        // HCA_FACTORY is public immutable on the base, accessible via harness
        assertEq(address(harness.HCA_FACTORY()), address(factory));
    }

    function test_msgSender_returns_original_when_not_hca() public {
        vm.prank(user);
        address sender = harness.exposedMsgSender();
        assertEq(sender, user, "_msgSender should return original sender when not HCA");
    }

    function test_msgSender_returns_owner_when_sender_is_hca() public {
        factory.setAccountOwner(hca, owner);

        vm.prank(hca);
        address sender = harness.exposedMsgSender();
        assertEq(sender, owner, "_msgSender should return account owner for HCA senders");
    }

    function test_msgSender_zero_owner_treated_as_eoa() public {
        // Ensure no owner is set for `user`
        vm.prank(user);
        address sender = harness.exposedMsgSender();
        assertEq(sender, user);
    }

    function test_msgSender_unrelated_mapping_does_not_affect_eoa() public {
        // Configure a different HCA mapping, but call from an unrelated EOA
        factory.setAccountOwner(hca, owner);

        vm.prank(user);
        address sender = harness.exposedMsgSender();
        assertEq(sender, user, "Unrelated mapping should not affect EOA sender");
    }

    function test_msgSender_owner_same_as_hca_returns_hca() public {
        // Edge: if factory maps HCA to itself, _msgSender returns that same address
        factory.setAccountOwner(hca, hca);

        vm.prank(hca);
        address sender = harness.exposedMsgSender();
        assertEq(sender, hca, "When owner == HCA, _msgSender should be the HCA address");
    }

    function test_msgSender_with_real_factory_requires_account_implementation_selection() public {
        address implementation = address(0x1234);
        HCAFactory realFactory =
            new HCAFactory(implementation, IHCAInitDataParser(address(0)), address(this));
        HCAEquivalenceHarness realHarness =
            new HCAEquivalenceHarness(IHCAFactoryBasic(address(realFactory)));

        vm.expectRevert(abi.encodeWithSelector(HCAFactory.HCAImplementationNotSet.selector, user));
        vm.prank(user);
        realHarness.exposedMsgSender();

        vm.prank(user);
        realFactory.setAccountImplementation(implementation);

        vm.prank(user);
        address sender = realHarness.exposedMsgSender();
        assertEq(sender, user);
    }

    function test_msgSender_with_real_factory_allows_contract_fallback_without_selection() public {
        HCAFactory realFactory =
            new HCAFactory(address(0x1234), IHCAInitDataParser(address(0)), address(this));
        HCAEquivalenceHarness realHarness =
            new HCAEquivalenceHarness(IHCAFactoryBasic(address(realFactory)));

        assertEq(realHarness.exposedMsgSender(), address(this));
    }
}
