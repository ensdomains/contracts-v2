// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase

import {Test} from "forge-std/Test.sol";

import {DefaultReverseRegistrar} from "@ens/contracts/reverseRegistrar/DefaultReverseRegistrar.sol";

import {
    DefaultReverseRegistrarHCAAdapter
} from "~src/reverse-registrar/DefaultReverseRegistrarHCAAdapter.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract DefaultReverseRegistrarHCAAdapterTest is Test {
    MockHCAFactoryBasic hcaFactory;
    DefaultReverseRegistrar defaultReverseRegistrar;
    DefaultReverseRegistrarHCAAdapter defaultAdapter;

    address owner = makeAddr("owner");
    address hca = makeAddr("hca");

    function setUp() public {
        hcaFactory = new MockHCAFactoryBasic();
        defaultReverseRegistrar = new DefaultReverseRegistrar();
        defaultAdapter = new DefaultReverseRegistrarHCAAdapter(hcaFactory, defaultReverseRegistrar);

        defaultReverseRegistrar.setController(address(defaultAdapter), true);
    }

    function test_constructor_sets_targets() public view {
        assertEq(address(defaultAdapter.HCA_FACTORY()), address(hcaFactory), "HCA_FACTORY");
        assertEq(
            address(defaultAdapter.DEFAULT_REVERSE_REGISTRAR()),
            address(defaultReverseRegistrar),
            "DEFAULT_REVERSE_REGISTRAR"
        );
    }

    function test_setNameForAddr_uses_hca_owner() public {
        string memory name = "primary.eth";
        hcaFactory.setAccountOwner(hca, owner);

        vm.prank(hca);
        defaultAdapter.setNameForAddr(name);

        assertEq(defaultReverseRegistrar.nameForAddr(owner), name, "owner name");
        assertEq(defaultReverseRegistrar.nameForAddr(hca), "", "hca name");
    }

    function test_setNameForAddr_uses_direct_sender_without_hca_mapping() public {
        string memory name = "primary.eth";

        vm.prank(owner);
        defaultAdapter.setNameForAddr(name);

        assertEq(defaultReverseRegistrar.nameForAddr(owner), name, "owner name");
    }
}
