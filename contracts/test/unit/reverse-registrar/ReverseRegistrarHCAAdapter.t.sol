// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase

import {Test} from "forge-std/Test.sol";

import {ENSRegistry} from "@ens/contracts/registry/ENSRegistry.sol";
import {ReverseRegistrar} from "@ens/contracts/reverseRegistrar/ReverseRegistrar.sol";
import {MockOwnable} from "@ens/contracts/test/mocks/MockOwnable.sol";

import {ReverseRegistrarHCAAdapter} from "~src/reverse-registrar/ReverseRegistrarHCAAdapter.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract ReverseRegistrarHCAAdapterTest is Test {
    bytes32 constant REVERSE_LABELHASH = keccak256("reverse");
    bytes32 constant ADDR_LABELHASH = keccak256("addr");
    bytes32 constant REVERSE_NODE = keccak256(abi.encodePacked(bytes32(0), REVERSE_LABELHASH));

    MockHCAFactoryBasic hcaFactory;
    ENSRegistry registry;
    ReverseRegistrar reverseRegistrar;
    ReverseRegistrarHCAAdapter reverseAdapter;

    address owner = makeAddr("owner");
    address hca = makeAddr("hca");
    address resolver = makeAddr("resolver");

    function setUp() public {
        hcaFactory = new MockHCAFactoryBasic();
        registry = new ENSRegistry();
        reverseRegistrar = new ReverseRegistrar(registry);
        reverseAdapter = new ReverseRegistrarHCAAdapter(hcaFactory, reverseRegistrar);

        registry.setSubnodeOwner(bytes32(0), REVERSE_LABELHASH, address(this));
        registry.setSubnodeOwner(REVERSE_NODE, ADDR_LABELHASH, address(reverseRegistrar));

        reverseRegistrar.setController(address(reverseAdapter), true);
    }

    function test_reverse_constructor_sets_targets() public view {
        assertEq(address(reverseAdapter.HCA_FACTORY()), address(hcaFactory), "HCA_FACTORY");
        assertEq(
            address(reverseAdapter.REVERSE_REGISTRAR()),
            address(reverseRegistrar),
            "REVERSE_REGISTRAR"
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

    function test_claimForContract_Ownable() external {
        hcaFactory.setAccountOwner(hca, owner);

        MockOwnable c = new MockOwnable(owner);

        vm.prank(hca);
        bytes32 node = reverseAdapter.claimForContract(address(c), resolver);

        assertEq(node, reverseRegistrar.node(address(c)), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }

    function test_claimForContract_IContractNamer() external {
        hcaFactory.setAccountOwner(hca, owner);

        MockContractNamer c = new MockContractNamer(owner);

        vm.prank(hca);
        bytes32 node = reverseAdapter.claimForContract(address(c), resolver);

        assertEq(node, reverseRegistrar.node(address(c)), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }
}


contract MockContractNamer is IContractNamer {
    address internal immutable NAMER;
    constructor(address namer) {
        NAMER = namer;
    }
    function isContractNamer(address namer) external view returns (bool) {
        return namer == NAMER;
    }
}
