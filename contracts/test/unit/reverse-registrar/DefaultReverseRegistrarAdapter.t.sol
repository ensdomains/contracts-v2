// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase

import {Test} from "forge-std/Test.sol";

import {DefaultReverseRegistrar} from "@ens/contracts/reverseRegistrar/DefaultReverseRegistrar.sol";
import {MockOwnable} from "@ens/contracts/test/mocks/MockOwnable.sol";

import {
    DefaultReverseRegistrarAdapter
} from "~src/reverse-registrar/DefaultReverseRegistrarAdapter.sol";
import {MockContractNamer} from "~test/mocks/MockContractNamer.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";

contract DefaultReverseRegistrarAdapterTest is Test {
    DefaultReverseRegistrar defaultReverseRegistrar;
    DefaultReverseRegistrarAdapter defaultAdapter;

    address owner = makeAddr("owner");
    string name = "primary.eth";

    function setUp() external {
        defaultReverseRegistrar = new DefaultReverseRegistrar();
        defaultAdapter = new DefaultReverseRegistrarAdapter(
            defaultReverseRegistrar,
            IContractNamer(address(0))
        );

        defaultReverseRegistrar.setController(address(defaultAdapter), true);
    }

    function test_constructor() external view {
        assertEq(
            address(defaultAdapter.DEFAULT_REVERSE_REGISTRAR()),
            address(defaultReverseRegistrar),
            "DEFAULT_REVERSE_REGISTRAR"
        );
    }

    function test_setName_EOA() external {
        vm.prank(owner);
        defaultAdapter.setName(owner, name);

        assertEq(defaultReverseRegistrar.nameForAddr(owner), name);
    }

    function test_setName_Ownable() external {
        MockOwnable c = new MockOwnable(owner);

        vm.prank(owner);
        defaultAdapter.setName(address(c), name);

        assertEq(defaultReverseRegistrar.nameForAddr(address(c)), name);
    }

    function test_setName_IContractNamer() external {
        MockContractNamer c = new MockContractNamer(owner);

        vm.prank(owner);
        defaultAdapter.setName(address(c), name);

        assertEq(defaultReverseRegistrar.nameForAddr(address(c)), name);
    }
}
