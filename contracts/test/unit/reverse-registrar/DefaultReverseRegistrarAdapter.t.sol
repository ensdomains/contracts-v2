// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {DefaultReverseRegistrar} from "@ens/contracts/reverseRegistrar/DefaultReverseRegistrar.sol";
import {MockOwnable} from "@ens/contracts/test/mocks/MockOwnable.sol";
import {
    VerifiableFactory
} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {
    IVerifiableFactory
} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {
    DefaultReverseRegistrarAdapter
} from "~src/reverse-registrar/DefaultReverseRegistrarAdapter.sol";
import {MockContractNamer} from "~test/mocks/MockContractNamer.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {AccountNamerLib} from "~src/reverse-registrar/libraries/AccountNamerLib.sol";
import {HCAAuthorizer} from "~src/hca/HCAAuthorizer.sol";
import {HCAFixture} from "~test/fixtures/HCAFixture.sol";

contract DefaultReverseRegistrarAdapterTest is HCAFixture {
    DefaultReverseRegistrar defaultReverseRegistrar;
    DefaultReverseRegistrarAdapter defaultAdapter;
    VerifiableFactory verifiableFactory;
    MockContractNamer delegatedNamer;

    address owner = makeAddr("owner");
    address actor = makeAddr("actor");
    string name = "primary.eth";

    function setUp() external {
        deployHCAFixture();

        defaultReverseRegistrar = new DefaultReverseRegistrar();
        verifiableFactory = new VerifiableFactory();
        delegatedNamer = new MockContractNamer(owner);

        defaultAdapter = new DefaultReverseRegistrarAdapter(
            defaultReverseRegistrar,
            verifiableFactory,
            trustedHCASet,
            delegatedNamer
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
        assertEq(
            address(defaultAdapter.TRUSTED_HCA_SET()),
            address(trustedHCASet),
            "TRUSTED_HCA_SET"
        );
        assertEq(address(defaultAdapter.CONTRACT_NAMER()), address(delegatedNamer), "CONTRACT_NAMER");
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(
                address(defaultAdapter),
                type(IContractNamer).interfaceId
            )
        );
    }

    function test_delegatesContractNamer() external view {
        assertTrue(defaultAdapter.isContractNamer(owner));
        assertFalse(defaultAdapter.isContractNamer(actor));
    }

    function test_setName_EOA() external {
        vm.prank(owner);
        defaultAdapter.setName(owner, name);

        assertEq(defaultReverseRegistrar.nameForAddr(owner), name);
    }

    function test_setName_revert_unauthorized() external {
        vm.expectRevert(abi.encodeWithSelector(AccountNamerLib.UnauthorizedNamer.selector, actor));
        vm.prank(actor);
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

    function test_setNameWithHCA_EOA() external {
        address hca = _deployHCA(verifiableFactory, owner, address(trustedHCAImpl));

        vm.prank(hca);
        defaultAdapter.setNameWithHCA(owner, name);

        assertEq(defaultReverseRegistrar.nameForAddr(owner), name);
        assertEq(defaultReverseRegistrar.nameForAddr(hca), "");
    }

    function test_setNameWithHCA_revert_hcaOwnerMismatch_ownable() external {
        address hca = _deployHCA(verifiableFactory, owner, address(trustedHCAImpl));
        MockOwnable c = new MockOwnable(owner);

        vm.expectRevert(
            abi.encodeWithSelector(HCAAuthorizer.HCAOwnerMismatch.selector, address(c), owner)
        );
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(address(c), name);
    }

    function test_setNameWithHCA_revert_hcaOwnerMismatch_contractNamer() external {
        address hca = _deployHCA(verifiableFactory, owner, address(trustedHCAImpl));
        MockContractNamer c = new MockContractNamer(owner);

        vm.expectRevert(
            abi.encodeWithSelector(HCAAuthorizer.HCAOwnerMismatch.selector, address(c), owner)
        );
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(address(c), name);
    }

    function test_setNameWithHCA_revert_hcaImplementationNotTrusted() external {
        address hca = _deployHCA(verifiableFactory, owner, address(untrustedHCAImpl));

        vm.expectRevert(
            abi.encodeWithSelector(
                HCAAuthorizer.HCAImplementationNotTrusted.selector,
                address(untrustedHCAImpl)
            )
        );
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(owner, name);
    }

    function test_setNameWithHCA_revert_hcaVerificationFailed() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IVerifiableFactory.VerificationFailed.selector,
                address(trustedHCAImpl)
            )
        );
        vm.prank(address(trustedHCAImpl));
        defaultAdapter.setNameWithHCA(owner, name);
    }

    function test_setNameWithHCA_revert_hcaOwnerReverts() external {
        address hca = _deployHCA(verifiableFactory, owner, address(revertingHCAImpl));

        vm.expectRevert(abi.encodeWithSelector(HCAAuthorizer.HCAOwnerUnavailable.selector, hca));
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(owner, name);
    }

    function test_setNameWithHCA_revert_hcaOwnerMismatch() external {
        address hca = _deployHCA(verifiableFactory, owner, address(trustedHCAImpl));

        vm.expectRevert(
            abi.encodeWithSelector(HCAAuthorizer.HCAOwnerMismatch.selector, actor, owner)
        );
        vm.prank(hca);
        defaultAdapter.setNameWithHCA(actor, name);
    }
}
