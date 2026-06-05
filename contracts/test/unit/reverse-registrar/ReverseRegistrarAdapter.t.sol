// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase

import {Test} from "forge-std/Test.sol";

import {ENSRegistry} from "@ens/contracts/registry/ENSRegistry.sol";
import {ReverseRegistrar} from "@ens/contracts/reverseRegistrar/ReverseRegistrar.sol";
import {MockOwnable} from "@ens/contracts/test/mocks/MockOwnable.sol";

import {MockContractNamer} from "~test/mocks/MockContractNamer.sol";
import {ReverseRegistrarAdapter} from "~src/reverse-registrar/ReverseRegistrarAdapter.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";

contract ReverseRegistrarAdapterTest is Test {
    bytes32 constant REVERSE_LABELHASH = keccak256("reverse");
    bytes32 constant ADDR_LABELHASH = keccak256("addr");
    bytes32 constant REVERSE_NODE = keccak256(abi.encodePacked(bytes32(0), REVERSE_LABELHASH));

    ENSRegistry registry;
    ReverseRegistrar reverseRegistrar;
    ReverseRegistrarAdapter reverseAdapter;

    address owner = makeAddr("owner");
    address resolver = makeAddr("resolver");

    function setUp() external {
        registry = new ENSRegistry();
        reverseRegistrar = new ReverseRegistrar(registry);
        reverseAdapter = new ReverseRegistrarAdapter(reverseRegistrar, IContractNamer(address(0)));

        registry.setSubnodeOwner(bytes32(0), REVERSE_LABELHASH, address(this));
        registry.setSubnodeOwner(REVERSE_NODE, ADDR_LABELHASH, address(reverseRegistrar));

        reverseRegistrar.setController(address(reverseAdapter), true);
    }

    function test_reverse_constructor() external view {
        assertEq(
            address(reverseAdapter.REVERSE_REGISTRAR()),
            address(reverseRegistrar),
            "REVERSE_REGISTRAR"
        );
    }

    function test_claimForAddr_EOA() external {
        vm.prank(owner);
        bytes32 node = reverseAdapter.claim(owner, resolver);

        assertEq(node, reverseRegistrar.node(owner), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }

    function test_claim_Ownable() external {
        MockOwnable c = new MockOwnable(owner);

        vm.prank(owner);
        bytes32 node = reverseAdapter.claim(address(c), resolver);

        assertEq(node, reverseRegistrar.node(address(c)), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }

    function test_claimForContract_IContractNamer() external {
        MockContractNamer c = new MockContractNamer(owner);

        vm.prank(owner);
        bytes32 node = reverseAdapter.claim(address(c), resolver);

        assertEq(node, reverseRegistrar.node(address(c)), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }
}
