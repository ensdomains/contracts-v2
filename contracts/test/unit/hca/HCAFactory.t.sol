// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {HCADeferredImplementation} from "~src/hca/HCADeferredImplementation.sol";
import {HCAFactory} from "~src/hca/HCAFactory.sol";
import {IHCAFactoryBasic} from "~src/hca/interfaces/IHCAFactoryBasic.sol";

contract MockHCAImplementation {
    event Initialized(bytes initData, uint256 value);

    bytes32 internal _lastInitDataHash;

    function initializeAccount(bytes calldata initData) external payable {
        _lastInitDataHash = keccak256(initData);
        emit Initialized(initData, msg.value);
    }

    function lastInitDataHash() external view returns (bytes32) {
        return _lastInitDataHash;
    }
}


contract MockSCA {}


contract MockAuthorizedHCAImplementation is IProxyAuthorization {
    uint256 internal _value;

    function canUpgradeFrom(address) external pure returns (bool) {
        return true;
    }

    function initializeValue(uint256 newValue) external {
        _value = newValue;
    }

    function value() external view returns (uint256) {
        return _value;
    }
}


contract MockOwnerFactory is IHCAFactoryBasic {
    address internal _owner;

    constructor(address owner_) {
        _owner = owner_;
    }

    function getAccountOwner(address) external view returns (address) {
        return _owner;
    }
}


contract HCAFactoryTest is Test {
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    VerifiableFactory verifiableFactory;
    HCAFactory factory;
    MockHCAImplementation implementation;
    HCADeferredImplementation deferredImplementation;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address nonOwner = makeAddr("nonOwner");

    function setUp() public {
        verifiableFactory = new VerifiableFactory();
        factory = new HCAFactory(verifiableFactory, owner);
        implementation = new MockHCAImplementation();
        deferredImplementation = new HCADeferredImplementation(
            IHCAFactoryBasic(address(factory))
        );
    }

    function test_constructor_setsOwner() external view {
        assertEq(
            address(factory.VERIFIABLE_FACTORY()),
            address(verifiableFactory),
            "verifiable factory"
        );
        assertEq(factory.owner(), owner, "owner");
        assertFalse(factory.isApprovedImplementation(address(implementation)), "approved");
        assertEq(factory.deferredImplementation(), address(0), "deferred implementation");
    }

    function test_constructor_revertsWhenVerifiableFactoryIsZero() external {
        vm.expectRevert(HCAFactory.VerifiableFactoryCannotBeZero.selector);
        new HCAFactory(VerifiableFactory(address(0)), owner);
    }

    function test_setImplementationApproval_approvesImplementation() external {
        vm.expectEmit(true, true, false, true, address(factory));
        emit HCAFactory.HCAImplementationApprovalChanged(address(implementation), true);

        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);

        assertTrue(factory.isApprovedImplementation(address(implementation)), "approved");
    }

    function test_setImplementationApproval_revertsWhenImplementationIsZero() external {
        vm.expectRevert(HCAFactory.HCAImplementationCannotBeZero.selector);
        vm.prank(owner);
        factory.setImplementationApproval(address(0), true);
    }

    function test_setImplementationApproval_revertsWhenNotOwner() external {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner)
        );
        vm.prank(nonOwner);
        factory.setImplementationApproval(address(implementation), true);
    }

    function test_setImplementationApproval_revokesImplementation() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);

        vm.expectEmit(true, false, false, true, address(factory));
        emit HCAFactory.HCAImplementationApprovalChanged(address(implementation), false);

        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), false);

        assertFalse(factory.isApprovedImplementation(address(implementation)), "approved");
    }

    function test_setDeferredImplementation_setsDeferredImplementation() external {
        vm.expectEmit(true, false, false, true, address(factory));
        emit HCAFactory.DeferredImplementationSet(address(deferredImplementation));

        vm.prank(owner);
        factory.setDeferredImplementation(address(deferredImplementation));

        assertEq(
            factory.deferredImplementation(),
            address(deferredImplementation),
            "deferred implementation"
        );
    }

    function test_setDeferredImplementation_revertsWhenImplementationIsZero() external {
        vm.expectRevert(HCAFactory.DeferredImplementationCannotBeZero.selector);
        vm.prank(owner);
        factory.setDeferredImplementation(address(0));
    }

    function test_setDeferredImplementation_revertsWhenNotOwner() external {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner)
        );
        vm.prank(nonOwner);
        factory.setDeferredImplementation(address(deferredImplementation));
    }

    function test_setAccountImplementation_setsApprovedImplementation() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);

        vm.expectEmit(true, true, false, true, address(factory));
        emit HCAFactory.AccountImplementationSet(user, address(implementation));

        vm.prank(user);
        factory.setAccountImplementation(address(implementation));

        assertEq(
            factory.accountImplementationOf(user),
            address(implementation),
            "account implementation"
        );
        assertEq(factory.getAccountOwner(user), address(0), "non-hca owner");
    }

    function test_setAccountImplementation_allowsDeferredImplementation() external {
        vm.prank(owner);
        factory.setDeferredImplementation(address(deferredImplementation));

        vm.expectEmit(true, true, false, true, address(factory));
        emit HCAFactory.AccountImplementationSet(user, address(deferredImplementation));

        vm.prank(user);
        factory.setAccountImplementation(address(deferredImplementation));

        assertEq(
            factory.accountImplementationOf(user),
            address(deferredImplementation),
            "account implementation"
        );
        assertEq(factory.getAccountOwner(user), address(0), "non-hca owner");
    }

    function test_setAccountImplementation_revertsWhenImplementationIsZero() external {
        vm.expectRevert(HCAFactory.HCAImplementationCannotBeZero.selector);
        vm.prank(user);
        factory.setAccountImplementation(address(0));
    }

    function test_setAccountImplementation_revertsWhenImplementationNotApproved() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                HCAFactory.HCAImplementationNotApproved.selector,
                address(implementation)
            )
        );
        vm.prank(user);
        factory.setAccountImplementation(address(implementation));
    }

    function test_setAccount_designatesExistingApprovedAccount() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);
        address sca = _deployVerifiableAccount(address(implementation));

        vm.expectEmit(true, true, true, true, address(factory));
        emit HCAFactory.AccountDesignated(user, sca, address(implementation));

        vm.prank(user);
        factory.setAccount(sca, address(implementation));

        assertEq(factory.getAccountOwner(sca), user, "hca owner");
        assertEq(
            factory.accountImplementationOf(sca),
            address(implementation),
            "account implementation"
        );
    }

    function test_setAccount_designatesExistingDeferredAccount() external {
        vm.prank(owner);
        factory.setDeferredImplementation(address(deferredImplementation));
        address sca = _deployVerifiableAccount(address(deferredImplementation));

        vm.expectEmit(true, true, true, true, address(factory));
        emit HCAFactory.AccountDesignated(user, sca, address(deferredImplementation));

        vm.prank(user);
        factory.setAccount(sca, address(deferredImplementation));

        assertEq(factory.getAccountOwner(sca), user, "hca owner");
        assertEq(
            factory.accountImplementationOf(sca),
            address(deferredImplementation),
            "account implementation"
        );
    }

    function test_setAccount_revertsWhenAccountIsZero() external {
        vm.expectRevert(HCAFactory.HCAAccountCannotBeZero.selector);
        vm.prank(user);
        factory.setAccount(address(0), address(implementation));
    }

    function test_setAccount_revertsWhenAccountHasNoCode() external {
        address sca = makeAddr("sca");

        vm.expectRevert(abi.encodeWithSelector(HCAFactory.HCAAccountHasNoCode.selector, sca));
        vm.prank(user);
        factory.setAccount(sca, address(implementation));
    }

    function test_setAccount_revertsWhenImplementationNotApproved() external {
        address sca = _deployVerifiableAccount(address(implementation));

        vm.expectRevert(
            abi.encodeWithSelector(
                HCAFactory.HCAImplementationNotApproved.selector,
                address(implementation)
            )
        );
        vm.prank(user);
        factory.setAccount(sca, address(implementation));
    }

    function test_setAccount_revertsWhenAccountIsNotVerifiable() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);
        address sca = address(new MockSCA());

        vm.expectRevert(
            abi.encodeWithSelector(
                HCAFactory.HCAAccountNotVerifiable.selector,
                sca,
                address(implementation)
            )
        );
        vm.prank(user);
        factory.setAccount(sca, address(implementation));
    }

    function test_setAccount_revertsWhenVerifiedForDifferentImplementation() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);
        MockHCAImplementation otherImplementation = new MockHCAImplementation();
        address sca = _deployVerifiableAccount(address(otherImplementation));

        vm.expectRevert(
            abi.encodeWithSelector(
                HCAFactory.HCAAccountNotVerifiable.selector,
                sca,
                address(implementation)
            )
        );
        vm.prank(user);
        factory.setAccount(sca, address(implementation));
    }

    function test_setAccount_revertsWhenAccountAlreadyDesignated() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);
        address sca = _deployVerifiableAccount(address(implementation));

        vm.prank(user);
        factory.setAccount(sca, address(implementation));

        vm.expectRevert(
            abi.encodeWithSelector(HCAFactory.HCAAccountAlreadyDesignated.selector, sca, user)
        );
        vm.prank(nonOwner);
        factory.setAccount(sca, address(implementation));
    }

    function test_getAccountOwner_revertsWhenAccountImplementationIsNotSet() external {
        vm.expectRevert(
            abi.encodeWithSelector(HCAFactory.HCAImplementationNotSet.selector, user)
        );
        factory.getAccountOwner(user);
    }

    function test_deferredImplementationUpgrade_revertsWhenFactoryIsZero() external {
        vm.expectRevert(HCADeferredImplementation.HCAFactoryCannotBeZero.selector);
        new HCADeferredImplementation(IHCAFactoryBasic(address(0)));
    }

    function test_deferredImplementationUpgrade_upgradesWhenCalledByHCAOwner() external {
        vm.prank(owner);
        factory.setDeferredImplementation(address(deferredImplementation));
        address sca = _deployVerifiableAccount(address(deferredImplementation));

        vm.prank(user);
        factory.setAccount(sca, address(deferredImplementation));

        MockAuthorizedHCAImplementation upgradeImplementation =
            new MockAuthorizedHCAImplementation();
        bytes memory initData = abi.encodeCall(
            MockAuthorizedHCAImplementation.initializeValue,
            (42)
        );

        vm.expectEmit(true, false, false, true, sca);
        emit IERC1967.Upgraded(address(upgradeImplementation));

        vm.prank(user);
        HCADeferredImplementation(sca).upgradeToAndCall(
            address(upgradeImplementation),
            initData
        );

        assertEq(_implementationOf(sca), address(upgradeImplementation), "implementation");
        assertEq(MockAuthorizedHCAImplementation(sca).value(), 42, "initialized value");
    }

    function test_deferredImplementationUpgrade_revertsWhenNotHCAOwner() external {
        vm.prank(owner);
        factory.setDeferredImplementation(address(deferredImplementation));
        address sca = _deployVerifiableAccount(address(deferredImplementation));

        vm.prank(user);
        factory.setAccount(sca, address(deferredImplementation));

        MockAuthorizedHCAImplementation upgradeImplementation =
            new MockAuthorizedHCAImplementation();

        vm.expectRevert(
            abi.encodeWithSelector(
                HCADeferredImplementation.CallerNotHCAOwner.selector,
                nonOwner,
                user
            )
        );
        vm.prank(nonOwner);
        HCADeferredImplementation(sca).upgradeToAndCall(address(upgradeImplementation), "");
    }

    function test_deferredImplementationUpgrade_revertsWhenImplementationHasNoCode() external {
        HCADeferredImplementation directDeferredImplementation =
            new HCADeferredImplementation(new MockOwnerFactory(user));
        address missingImplementation = makeAddr("missingImplementation");

        vm.expectRevert(
            abi.encodeWithSelector(
                HCADeferredImplementation.HCAImplementationHasNoCode.selector,
                missingImplementation
            )
        );
        vm.prank(user);
        directDeferredImplementation.upgradeToAndCall(missingImplementation, "");
    }

    function test_deferredImplementationUpgrade_revertsWhenOwnerIsUnset() external {
        HCADeferredImplementation directDeferredImplementation =
            new HCADeferredImplementation(new MockOwnerFactory(address(0)));

        MockAuthorizedHCAImplementation upgradeImplementation =
            new MockAuthorizedHCAImplementation();

        vm.expectRevert(
            abi.encodeWithSelector(
                HCADeferredImplementation.HCAOwnerNotSet.selector,
                address(directDeferredImplementation)
            )
        );
        vm.prank(user);
        directDeferredImplementation.upgradeToAndCall(address(upgradeImplementation), "");
    }

    function test_deferredImplementationProxyUpgrade_revertsWhenTargetCannotAuthorizeUpgrade()
        external
    {
        vm.prank(owner);
        factory.setDeferredImplementation(address(deferredImplementation));
        address sca = _deployVerifiableAccount(address(deferredImplementation));

        vm.prank(user);
        factory.setAccount(sca, address(deferredImplementation));

        address missingImplementation = makeAddr("missingImplementation");

        vm.expectRevert();
        vm.prank(user);
        HCADeferredImplementation(sca).upgradeToAndCall(missingImplementation, "");
    }

    function _deployVerifiableAccount(address implementation_) internal returns (address) {
        return
            verifiableFactory.deployProxy(implementation_, uint256(uint160(implementation_)), "");
    }

    function _implementationOf(address proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(proxy, IMPLEMENTATION_SLOT))));
    }
}
