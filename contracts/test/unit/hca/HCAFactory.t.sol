// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {Test} from "forge-std/Test.sol";

import {HCADeferredImplementation} from "~src/hca/HCADeferredImplementation.sol";
import {HCAFactory} from "~src/hca/HCAFactory.sol";
import {IHCAInitDataParser} from "~src/hca/interfaces/IHCAInitDataParser.sol";

contract MockHCAInitDataParser is IHCAInitDataParser {
    function getOwnerFromInitData(bytes calldata initData) external pure returns (address hcaOwner) {
        hcaOwner = abi.decode(initData, (address));
    }
}

contract MockHCAImplementation {
    bytes32 internal _lastInitDataHash;
    uint256 internal _value;

    function initializeAccount(bytes calldata initData) external payable {
        _lastInitDataHash = keccak256(initData);
    }

    function initializeValue(uint256 value_) external {
        _value = value_;
    }

    function lastInitDataHash() external view returns (bytes32) {
        return _lastInitDataHash;
    }

    function value() external view returns (uint256) {
        return _value;
    }
}

contract HCAFactoryTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    event AccountCreated(address indexed hcaOwner, address indexed hca);
    event NewHCAImplementation(address indexed accountImplementation, address indexed initDataParser);
    event AccountImplementationSet(address indexed account, address indexed implementation);
    event Upgraded(address indexed implementation);

    HCAFactory factory;
    HCADeferredImplementation deferredImplementation;
    MockHCAInitDataParser parser;
    MockHCAImplementation implementation;

    address user = address(0x1111);
    address other = address(0x2222);

    function setUp() public {
        parser = new MockHCAInitDataParser();
        implementation = new MockHCAImplementation();
        factory = new HCAFactory(address(implementation), parser, address(this));
        deferredImplementation = HCADeferredImplementation(factory.deferredImplementation());
    }

    function test_constructor_sets_initial_configuration() public view {
        assertEq(factory.owner(), address(this));
        assertEq(factory.implementation(), address(implementation));
        assertEq(address(factory.initDataParser()), address(parser));
        assertEq(factory.deferredImplementation(), address(deferredImplementation));
        assertEq(address(deferredImplementation.HCA_FACTORY()), address(factory));
    }

    function test_setImplementation_updates_current_configuration() public {
        MockHCAImplementation newImplementation = new MockHCAImplementation();
        MockHCAInitDataParser newParser = new MockHCAInitDataParser();

        vm.expectEmit(true, true, false, true, address(factory));
        emit NewHCAImplementation(address(newImplementation), address(newParser));
        factory.setImplementation(address(newImplementation), newParser);

        assertEq(factory.implementation(), address(newImplementation));
        assertEq(address(factory.initDataParser()), address(newParser));
    }

    function test_setImplementation_reverts_when_not_owner() public {
        MockHCAImplementation newImplementation = new MockHCAImplementation();
        MockHCAInitDataParser newParser = new MockHCAInitDataParser();

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, user));
        vm.prank(user);
        factory.setImplementation(address(newImplementation), newParser);
    }

    function test_setAccountImplementation_selects_current_implementation() public {
        vm.expectEmit(true, true, false, true, address(factory));
        emit AccountImplementationSet(user, address(implementation));
        vm.prank(user);
        factory.setAccountImplementation(address(implementation));

        assertEq(factory.accountImplementationOf(user), address(implementation));
    }

    function test_setAccountImplementation_selects_deferred_implementation() public {
        vm.expectEmit(true, true, false, true, address(factory));
        emit AccountImplementationSet(user, address(deferredImplementation));
        vm.prank(user);
        factory.setAccountImplementation(address(deferredImplementation));

        assertEq(factory.accountImplementationOf(user), address(deferredImplementation));
    }

    function test_setAccountImplementation_reverts_for_unselectable_implementation() public {
        vm.expectRevert(abi.encodeWithSelector(HCAFactory.HCAImplementationNotSelectable.selector, address(0)));
        vm.prank(user);
        factory.setAccountImplementation(address(0));

        vm.expectRevert(abi.encodeWithSelector(HCAFactory.HCAImplementationNotSelectable.selector, other));
        vm.prank(user);
        factory.setAccountImplementation(other);
    }

    function test_getAccountOwner_reverts_until_account_selects_implementation() public {
        vm.expectRevert(abi.encodeWithSelector(HCAFactory.HCAImplementationNotSet.selector, user));
        factory.getAccountOwner(user);

        vm.prank(user);
        factory.setAccountImplementation(address(implementation));

        assertEq(factory.getAccountOwner(user), address(0));
    }

    function test_getAccountOwner_returns_zero_for_contract_without_implementation_selection() public view {
        assertEq(factory.getAccountOwner(address(this)), address(0));
    }

    function test_createAccount_deploys_initialized_account_with_current_implementation() public {
        bytes memory initData = abi.encode(user);
        address payable predicted = factory.computeAccountAddress(user);

        vm.expectEmit(true, true, false, true, address(factory));
        emit AccountCreated(user, predicted);
        address payable hca = factory.createAccount(initData);

        assertEq(hca, predicted);
        assertEq(factory.getAccountOwner(hca), user);
        assertEq(_proxyImplementation(hca), address(implementation));
        assertEq(MockHCAImplementation(hca).lastInitDataHash(), keccak256(initData));
        assertEq(factory.accountImplementationOf(user), address(0));
    }

    function test_createAccount_uses_selected_implementation_over_current() public {
        bytes memory initData = abi.encode(user);
        address payable predicted = factory.computeAccountAddress(user);
        MockHCAImplementation newImplementation = new MockHCAImplementation();

        vm.prank(user);
        factory.setAccountImplementation(address(implementation));
        factory.setImplementation(address(newImplementation), parser);

        vm.expectEmit(true, true, false, true, address(factory));
        emit AccountCreated(user, predicted);
        address payable hca = factory.createAccount(initData);

        assertEq(hca, predicted);
        assertEq(factory.getAccountOwner(hca), user);
        assertEq(_proxyImplementation(hca), address(implementation));
        assertEq(MockHCAImplementation(hca).lastInitDataHash(), keccak256(initData));
    }

    function test_createAccount_funds_existing_account() public {
        bytes memory initData = abi.encode(user);
        vm.deal(address(this), 1 ether);

        address payable hca = factory.createAccount(initData);
        assertEq(hca.balance, 0);

        address payable existingHca = factory.createAccount{value: 1 ether}(initData);

        assertEq(existingHca, hca);
        assertEq(hca.balance, 1 ether);
    }

    function test_createAccount_deploys_deferred_account_that_owner_can_upgrade() public {
        bytes memory initData = abi.encode(user);
        vm.prank(user);
        factory.setAccountImplementation(address(deferredImplementation));

        address payable hca = factory.createAccount(initData);
        MockHCAImplementation newImplementation = new MockHCAImplementation();

        bytes memory initializeData = abi.encodeCall(MockHCAImplementation.initializeValue, (42));

        vm.expectEmit(true, false, false, true, hca);
        emit Upgraded(address(newImplementation));
        vm.prank(user);
        HCADeferredImplementation(hca).upgradeToAndCall(address(newImplementation), initializeData);

        assertEq(MockHCAImplementation(hca).value(), 42);
    }

    function test_deferredUpgrade_reverts_when_not_owner() public {
        bytes memory initData = abi.encode(user);
        vm.prank(user);
        factory.setAccountImplementation(address(deferredImplementation));
        address payable hca = factory.createAccount(initData);
        MockHCAImplementation newImplementation = new MockHCAImplementation();

        vm.expectRevert(
            abi.encodeWithSelector(HCADeferredImplementation.HCADeferredUpgradeUnauthorized.selector, other, user)
        );
        vm.prank(other);
        HCADeferredImplementation(hca).upgradeToAndCall(address(newImplementation), "");
    }

    function test_deferredUpgrade_reverts_when_new_implementation_has_no_code() public {
        bytes memory initData = abi.encode(user);
        vm.prank(user);
        factory.setAccountImplementation(address(deferredImplementation));
        address payable hca = factory.createAccount(initData);

        vm.expectRevert(
            abi.encodeWithSelector(HCADeferredImplementation.HCADeferredImplementationHasNoCode.selector, other)
        );
        vm.prank(user);
        HCADeferredImplementation(hca).upgradeToAndCall(other, "");
    }

    function _proxyImplementation(address hca) internal view returns (address) {
        return address(uint160(uint256(vm.load(hca, IMPLEMENTATION_SLOT))));
    }
}
