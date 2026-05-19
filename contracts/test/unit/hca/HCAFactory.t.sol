// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {HCAFactory} from "~src/hca/HCAFactory.sol";

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


contract HCAFactoryTest is Test {
    VerifiableFactory verifiableFactory;
    HCAFactory factory;
    MockHCAImplementation implementation;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address nonOwner = makeAddr("nonOwner");

    function setUp() public {
        verifiableFactory = new VerifiableFactory();
        factory = new HCAFactory(verifiableFactory, owner);
        implementation = new MockHCAImplementation();
    }

    function test_constructor_setsOwner() external view {
        assertEq(
            address(factory.VERIFIABLE_FACTORY()),
            address(verifiableFactory),
            "verifiable factory"
        );
        assertEq(factory.owner(), owner, "owner");
        assertFalse(factory.isApprovedImplementation(address(implementation)), "approved");
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

    function test_setAccount_designatesExistingApprovedAccount() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);
        address sca = _deployVerifiableAccount(address(implementation));

        vm.expectEmit(true, true, true, true, address(factory));
        emit HCAFactory.AccountDesignated(user, sca, address(implementation));

        vm.prank(user);
        factory.setAccount(sca, address(implementation));

        assertEq(factory.getAccountOwner(sca), user, "hca owner");
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

    function _deployVerifiableAccount(address implementation_) internal returns (address) {
        return
            verifiableFactory.deployProxy(implementation_, uint256(uint160(implementation_)), "");
    }
}
