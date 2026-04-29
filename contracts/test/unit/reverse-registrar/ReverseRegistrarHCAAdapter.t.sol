// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase

import {Test} from "forge-std/Test.sol";

import {ENSRegistry} from "@ens/contracts/registry/ENSRegistry.sol";
import {DefaultReverseRegistrar} from "@ens/contracts/reverseRegistrar/DefaultReverseRegistrar.sol";
import {ReverseRegistrar} from "@ens/contracts/reverseRegistrar/ReverseRegistrar.sol";

import {
    DefaultReverseRegistrarHCAAdapter
} from "~src/reverse-registrar/DefaultReverseRegistrarHCAAdapter.sol";
import {ReverseRegistrarHCAAdapter} from "~src/reverse-registrar/ReverseRegistrarHCAAdapter.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract ReverseRegistrarHCAAdapterTest is Test {
    bytes32 constant REVERSE_LABELHASH = keccak256("reverse");
    bytes32 constant ADDR_LABELHASH = keccak256("addr");
    bytes32 constant REVERSE_NODE = keccak256(abi.encodePacked(bytes32(0), REVERSE_LABELHASH));

    MockHCAFactoryBasic hcaFactory;
    ENSRegistry registry;
    ReverseRegistrar reverseRegistrar;
    DefaultReverseRegistrar defaultReverseRegistrar;
    ReverseRegistrarHCAAdapter reverseAdapter;
    DefaultReverseRegistrarHCAAdapter defaultAdapter;

    address owner = makeAddr("owner");
    address hca = makeAddr("hca");
    address resolver = makeAddr("resolver");

    function setUp() public {
        hcaFactory = new MockHCAFactoryBasic();
        registry = new ENSRegistry();
        reverseRegistrar = new ReverseRegistrar(registry);
        defaultReverseRegistrar = new DefaultReverseRegistrar();
        reverseAdapter = new ReverseRegistrarHCAAdapter(hcaFactory, reverseRegistrar);
        defaultAdapter = new DefaultReverseRegistrarHCAAdapter(hcaFactory, defaultReverseRegistrar);

        registry.setSubnodeOwner(bytes32(0), REVERSE_LABELHASH, address(this));
        registry.setSubnodeOwner(REVERSE_NODE, ADDR_LABELHASH, address(reverseRegistrar));

        reverseRegistrar.setController(address(reverseAdapter), true);
        defaultReverseRegistrar.setController(address(defaultAdapter), true);
    }

    function test_reverse_constructor_sets_targets() public view {
        assertEq(address(reverseAdapter.HCA_FACTORY()), address(hcaFactory), "HCA_FACTORY");
        assertEq(
            address(reverseAdapter.REVERSE_REGISTRAR()),
            address(reverseRegistrar),
            "REVERSE_REGISTRAR"
        );
    }

    function test_default_constructor_sets_targets() public view {
        assertEq(address(defaultAdapter.HCA_FACTORY()), address(hcaFactory), "HCA_FACTORY");
        assertEq(
            address(defaultAdapter.DEFAULT_REVERSE_REGISTRAR()),
            address(defaultReverseRegistrar),
            "DEFAULT_REVERSE_REGISTRAR"
        );
    }

    function test_claimForAddr_uses_hca_owner_for_addr_and_owner() public {
        hcaFactory.setAccountOwner(hca, owner);

        vm.prank(hca);
        bytes32 node = reverseAdapter.claimForAddr(resolver);

        assertEq(node, reverseRegistrar.node(owner), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }

    function test_claimForAddr_uses_direct_sender_without_hca_mapping() public {
        vm.prank(owner);
        bytes32 node = reverseAdapter.claimForAddr(resolver);

        assertEq(node, reverseRegistrar.node(owner), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
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
