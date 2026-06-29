// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase

import {Test} from "forge-std/Test.sol";

import {DefaultReverseRegistrar} from "@ens/contracts/reverseRegistrar/DefaultReverseRegistrar.sol";
import {MockOwnable} from "@ens/contracts/test/mocks/MockOwnable.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {
    DefaultReverseRegistrarAdapter
} from "~src/reverse-registrar/DefaultReverseRegistrarAdapter.sol";
import {MockContractNamer} from "~test/mocks/MockContractNamer.sol";
import {MockHCA} from "~test/mocks/MockHCA.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {AccountNamerLib} from "~src/reverse-registrar/libraries/AccountNamerLib.sol";
import {HCAAuthorizer} from "~src/utils/HCAAuthorizer.sol";

contract DefaultReverseRegistrarAdapterTest is Test {
    DefaultReverseRegistrar defaultReverseRegistrar;
    DefaultReverseRegistrarAdapter defaultAdapter;
    VerifiableFactory verifiableFactory;
    MockContractNamer delegatedNamer;
    MockHCA hcaImplementation;
    MockHCA otherHCAImplementation;

    address owner = makeAddr("owner");
    address adapterOwner = makeAddr("adapterOwner");
    address other = makeAddr("other");
    string name = "primary.eth";
    uint256 nextSalt = 1;

    function setUp() external {
        defaultReverseRegistrar = new DefaultReverseRegistrar();
        verifiableFactory = new VerifiableFactory();
        delegatedNamer = new MockContractNamer(owner);
        hcaImplementation = new MockHCA();
        otherHCAImplementation = new MockHCA();

        address[] memory trustedHCAImplementations = new address[](1);
        trustedHCAImplementations[0] = address(hcaImplementation);
        defaultAdapter = new DefaultReverseRegistrarAdapter(
            defaultReverseRegistrar,
            delegatedNamer,
            verifiableFactory,
            adapterOwner,
            trustedHCAImplementations
        );

        defaultReverseRegistrar.setController(address(defaultAdapter), true);
    }

    function test_constructor() external view {
        assertEq(
            address(defaultAdapter.DEFAULT_REVERSE_REGISTRAR()),
            address(defaultReverseRegistrar),
            "DEFAULT_REVERSE_REGISTRAR"
        );
        assertEq(
            address(defaultAdapter.VERIFIABLE_FACTORY()),
            address(verifiableFactory),
            "VERIFIABLE_FACTORY"
        );
        assertEq(address(defaultAdapter.CONTRACT_NAMER()), address(delegatedNamer), "CONTRACT_NAMER");
        assertEq(defaultAdapter.owner(), adapterOwner, "owner");
        assertTrue(defaultAdapter.trustedHCAImplementations(address(hcaImplementation)), "trusted");
        assertFalse(
            defaultAdapter.trustedHCAImplementations(address(otherHCAImplementation)),
            "untrusted"
        );
    }

    function test_constructor_revert_verifiableFactoryCannotBeZero() external {
        address[] memory trustedHCAImplementations = new address[](0);

        vm.expectRevert(HCAAuthorizer.VerifiableFactoryCannotBeZero.selector);
        new DefaultReverseRegistrarAdapter(
            defaultReverseRegistrar,
            delegatedNamer,
            VerifiableFactory(address(0)),
            adapterOwner,
            trustedHCAImplementations
        );
    }

    function test_constructor_revert_initialHCAImplementationCannotBeZero() external {
        address[] memory trustedHCAImplementations = new address[](1);

        vm.expectRevert(HCAAuthorizer.HCAImplementationCannotBeZero.selector);
        new DefaultReverseRegistrarAdapter(
            defaultReverseRegistrar,
            delegatedNamer,
            verifiableFactory,
            adapterOwner,
            trustedHCAImplementations
        );
    }

    function test_supportsInterface() external view {
        assertTrue(defaultAdapter.supportsInterface(type(IContractNamer).interfaceId));
        assertFalse(defaultAdapter.supportsInterface(0xffffffff));
    }

    function test_delegatesContractNamer() external view {
        assertTrue(defaultAdapter.isContractNamer(owner));
        assertFalse(defaultAdapter.isContractNamer(other));
    }

    function test_setName_EOA() external {
        vm.prank(owner);
        defaultAdapter.setName(owner, name);

        assertEq(defaultReverseRegistrar.nameForAddr(owner), name);
    }

    function test_setName_revert_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(AccountNamerLib.UnauthorizedNamer.selector, other));
        vm.prank(other);
        defaultAdapter.setName(owner, name);
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

    function test_setTrustedHCAImplementation() external {
        vm.expectEmit(true, true, true, true);
        emit HCAAuthorizer.TrustedHCAImplementationUpdated(address(otherHCAImplementation), true);

        vm.prank(adapterOwner);
        defaultAdapter.setTrustedHCAImplementation(address(otherHCAImplementation), true);

        assertTrue(
            defaultAdapter.trustedHCAImplementations(address(otherHCAImplementation)),
            "trusted"
        );
    }

    function test_setTrustedHCAImplementation_revert_onlyOwner() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        defaultAdapter.setTrustedHCAImplementation(address(otherHCAImplementation), true);
    }

    function test_setNameWithHCA_EOA() external {
        address hca = _deployHCA(owner, address(hcaImplementation));

        vm.prank(hca);
        defaultAdapter.setNameWithHCA(owner, name);

        assertEq(defaultReverseRegistrar.nameForAddr(owner), name);
        assertEq(defaultReverseRegistrar.nameForAddr(hca), "");
    }

    function test_setNameWithHCA_revert_notOwner_ownable() external {
        address hca = _deployHCA(owner, address(hcaImplementation));
        MockOwnable c = new MockOwnable(owner);

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCANotOwner.selector, hca, address(c)));
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(address(c), name);
    }

    function test_setNameWithHCA_revert_notOwner_contractNamer() external {
        address hca = _deployHCA(owner, address(hcaImplementation));
        MockContractNamer c = new MockContractNamer(owner);

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCANotOwner.selector, hca, address(c)));
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(address(c), name);
    }

    function test_setNameWithHCA_revert_notOwner_whenExpired() external {
        address hca = _deployHCA(owner, address(hcaImplementation));
        MockHCA(hca).setExpired(true);

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCANotOwner.selector, hca, owner));
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(owner, name);
    }

    function test_setNameWithHCA_revert_hcaImplementationNotTrusted() external {
        address hca = _deployHCA(owner, address(otherHCAImplementation));

        vm.expectRevert(
            abi.encodeWithSelector(
                HCAAuthorizer.HCAImplementationNotTrusted.selector,
                address(otherHCAImplementation)
            )
        );
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(owner, name);
    }

    function test_setNameWithHCA_revert_notOwner() external {
        address hca = _deployHCA(owner, address(hcaImplementation));

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCANotOwner.selector, hca, other));
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(other, name);
    }

    function _deployHCA(address hcaOwner, address hcaImplementation_) internal returns (address) {
        bytes memory data = abi.encodeCall(MockHCA.initialize, (hcaOwner));
        vm.prank(owner);
        return verifiableFactory.deployProxy(hcaImplementation_, nextSalt++, data);
    }
}
