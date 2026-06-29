// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase

import {Test} from "forge-std/Test.sol";

import {ENSRegistry} from "@ens/contracts/registry/ENSRegistry.sol";
import {ReverseRegistrar} from "@ens/contracts/reverseRegistrar/ReverseRegistrar.sol";
import {MockOwnable} from "@ens/contracts/test/mocks/MockOwnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {MockContractNamer} from "~test/mocks/MockContractNamer.sol";
import {MockHCA} from "~test/mocks/MockHCA.sol";
import {ReverseRegistrarAdapter} from "~src/reverse-registrar/ReverseRegistrarAdapter.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {AccountNamerLib} from "~src/reverse-registrar/libraries/AccountNamerLib.sol";
import {HCAAuthorizer} from "~src/utils/HCAAuthorizer.sol";

contract ReverseRegistrarAdapterTest is Test {
    bytes32 constant REVERSE_LABELHASH = keccak256("reverse");
    bytes32 constant ADDR_LABELHASH = keccak256("addr");
    bytes32 constant REVERSE_NODE = keccak256(abi.encodePacked(bytes32(0), REVERSE_LABELHASH));

    ENSRegistry registry;
    ReverseRegistrar reverseRegistrar;
    ReverseRegistrarAdapter reverseAdapter;
    VerifiableFactory verifiableFactory;
    MockContractNamer delegatedNamer;
    MockHCA hcaImplementation;
    MockHCA otherHCAImplementation;

    address owner = makeAddr("owner");
    address adapterOwner = makeAddr("adapterOwner");
    address other = makeAddr("other");
    address resolver = makeAddr("resolver");
    uint256 nextSalt = 1;

    function setUp() external {
        registry = new ENSRegistry();
        reverseRegistrar = new ReverseRegistrar(registry);
        verifiableFactory = new VerifiableFactory();
        delegatedNamer = new MockContractNamer(owner);
        hcaImplementation = new MockHCA();
        otherHCAImplementation = new MockHCA();

        address[] memory trustedHCAImplementations = new address[](1);
        trustedHCAImplementations[0] = address(hcaImplementation);
        reverseAdapter = new ReverseRegistrarAdapter(
            reverseRegistrar,
            delegatedNamer,
            verifiableFactory,
            adapterOwner,
            trustedHCAImplementations
        );

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
        assertEq(
            address(reverseAdapter.VERIFIABLE_FACTORY()),
            address(verifiableFactory),
            "VERIFIABLE_FACTORY"
        );
        assertEq(address(reverseAdapter.CONTRACT_NAMER()), address(delegatedNamer), "CONTRACT_NAMER");
        assertEq(reverseAdapter.owner(), adapterOwner, "owner");
        assertTrue(reverseAdapter.trustedHCAImplementations(address(hcaImplementation)), "trusted");
        assertFalse(
            reverseAdapter.trustedHCAImplementations(address(otherHCAImplementation)),
            "untrusted"
        );
    }

    function test_supportsInterface() external view {
        assertTrue(reverseAdapter.supportsInterface(type(IContractNamer).interfaceId));
        assertFalse(reverseAdapter.supportsInterface(0xffffffff));
    }

    function test_delegatesContractNamer() external view {
        assertTrue(reverseAdapter.isContractNamer(owner));
        assertFalse(reverseAdapter.isContractNamer(other));
    }

    function test_constructor_revert_verifiableFactoryCannotBeZero() external {
        address[] memory trustedHCAImplementations = new address[](0);

        vm.expectRevert(HCAAuthorizer.VerifiableFactoryCannotBeZero.selector);
        new ReverseRegistrarAdapter(
            reverseRegistrar,
            delegatedNamer,
            VerifiableFactory(address(0)),
            adapterOwner,
            trustedHCAImplementations
        );
    }

    function test_constructor_revert_initialHCAImplementationCannotBeZero() external {
        address[] memory trustedHCAImplementations = new address[](1);

        vm.expectRevert(HCAAuthorizer.HCAImplementationCannotBeZero.selector);
        new ReverseRegistrarAdapter(
            reverseRegistrar,
            delegatedNamer,
            verifiableFactory,
            adapterOwner,
            trustedHCAImplementations
        );
    }

    function test_claim_EOA() external {
        vm.prank(owner);
        bytes32 node = reverseAdapter.claim(owner, resolver);

        assertEq(node, reverseRegistrar.node(owner), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }

    function test_claim_revert_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(AccountNamerLib.UnauthorizedNamer.selector, other));
        vm.prank(other);
        reverseAdapter.claim(owner, resolver);
    }

    function test_claim_Ownable() external {
        MockOwnable c = new MockOwnable(owner);

        vm.prank(owner);
        bytes32 node = reverseAdapter.claim(address(c), resolver);

        assertEq(node, reverseRegistrar.node(address(c)), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }

    function test_claim_IContractNamer() external {
        MockContractNamer c = new MockContractNamer(owner);

        vm.prank(owner);
        bytes32 node = reverseAdapter.claim(address(c), resolver);

        assertEq(node, reverseRegistrar.node(address(c)), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }

    function test_setTrustedHCAImplementation() external {
        vm.expectEmit(true, true, true, true);
        emit HCAAuthorizer.TrustedHCAImplementationUpdated(address(otherHCAImplementation), true);

        vm.prank(adapterOwner);
        reverseAdapter.setTrustedHCAImplementation(address(otherHCAImplementation), true);

        assertTrue(
            reverseAdapter.trustedHCAImplementations(address(otherHCAImplementation)),
            "trusted"
        );

        vm.prank(adapterOwner);
        reverseAdapter.setTrustedHCAImplementation(address(otherHCAImplementation), false);

        assertFalse(
            reverseAdapter.trustedHCAImplementations(address(otherHCAImplementation)),
            "untrusted"
        );
    }

    function test_setTrustedHCAImplementation_revert_onlyOwner() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        reverseAdapter.setTrustedHCAImplementation(address(otherHCAImplementation), true);
    }

    function test_setTrustedHCAImplementation_revert_hcaImplementationCannotBeZero() external {
        vm.expectRevert(HCAAuthorizer.HCAImplementationCannotBeZero.selector);
        vm.prank(adapterOwner);
        reverseAdapter.setTrustedHCAImplementation(address(0), true);
    }

    function test_claimWithHCA_EOA() external {
        address hca = _deployHCA(owner, address(hcaImplementation));

        vm.prank(hca);
        bytes32 node = reverseAdapter.claimWithHCA(owner, resolver);

        assertEq(node, reverseRegistrar.node(owner), "node");
        assertEq(registry.owner(node), owner, "owner");
        assertEq(registry.resolver(node), resolver, "resolver");
    }

    function test_claimWithHCA_revert_notOwner_ownable() external {
        address hca = _deployHCA(owner, address(hcaImplementation));
        MockOwnable c = new MockOwnable(owner);

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCANotOwner.selector, hca, address(c)));
        vm.prank(hca);
        reverseAdapter.claimWithHCA(address(c), resolver);
    }

    function test_claimWithHCA_revert_notOwner_contractNamer() external {
        address hca = _deployHCA(owner, address(hcaImplementation));
        MockContractNamer c = new MockContractNamer(owner);

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCANotOwner.selector, hca, address(c)));
        vm.prank(hca);
        reverseAdapter.claimWithHCA(address(c), resolver);
    }

    function test_claimWithHCA_revert_hcaImplementationNotTrusted() external {
        address hca = _deployHCA(owner, address(otherHCAImplementation));

        vm.expectRevert(
            abi.encodeWithSelector(
                HCAAuthorizer.HCAImplementationNotTrusted.selector,
                address(otherHCAImplementation)
            )
        );
        vm.prank(hca);
        reverseAdapter.claimWithHCA(owner, resolver);
    }

    function test_claimWithHCA_revert_hcaVerificationFailed() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IVerifiableFactory.VerificationFailed.selector,
                address(hcaImplementation)
            )
        );
        vm.prank(address(hcaImplementation));
        reverseAdapter.claimWithHCA(owner, resolver);
    }

    function test_claimWithHCA_revert_notOwner_whenOwnerZero() external {
        address hca = _deployHCA(address(0), address(hcaImplementation));

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCANotOwner.selector, hca, owner));
        vm.prank(hca);
        reverseAdapter.claimWithHCA(owner, resolver);
    }

    function test_claimWithHCA_revert_notOwner_whenExpired() external {
        address hca = _deployHCA(owner, address(hcaImplementation));
        MockHCA(hca).setExpired(true);

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCANotOwner.selector, hca, owner));
        vm.prank(hca);
        reverseAdapter.claimWithHCA(owner, resolver);
    }

    function test_claimWithHCA_revert_notOwner() external {
        address hca = _deployHCA(owner, address(hcaImplementation));

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCANotOwner.selector, hca, other));
        vm.prank(hca);
        reverseAdapter.claimWithHCA(other, resolver);
    }

    function _deployHCA(address hcaOwner, address hcaImplementation_) internal returns (address) {
        bytes memory data = abi.encodeCall(MockHCA.initialize, (hcaOwner));
        vm.prank(owner);
        return verifiableFactory.deployProxy(hcaImplementation_, nextSalt++, data);
    }
}
