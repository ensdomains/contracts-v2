// SPDX-License-Identifier: MIT
pragma solidity >=0.8.27;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

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

contract MockSCA {
    address internal immutable IMPLEMENTATION;

    constructor(address implementation_) {
        IMPLEMENTATION = implementation_;
    }

    function getImplementation() external view returns (address) {
        return IMPLEMENTATION;
    }
}

contract HCAFactoryTest is Test {
    HCAFactory factory;
    MockHCAImplementation implementation;

    address owner = makeAddr("owner");
    address user = makeAddr("user");
    address nonOwner = makeAddr("nonOwner");

    bytes initData = abi.encode(uint256(1), user);

    function setUp() public {
        factory = new HCAFactory(owner);
        implementation = new MockHCAImplementation();
    }

    function test_constructor_setsOwner() external view {
        assertEq(factory.owner(), owner, "owner");
        assertEq(factory.getImplementation(), address(0), "implementation");
        assertFalse(factory.approvedImplementations(address(implementation)), "approved");
    }

    function test_setImplementationApproval_approvesImplementation() external {
        vm.expectEmit(true, true, false, true, address(factory));
        emit HCAFactory.HCAImplementationApprovalChanged(address(implementation), true);

        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);

        assertTrue(factory.approvedImplementations(address(implementation)), "approved");
    }

    function test_setImplementationApproval_revertsWhenImplementationIsZero() external {
        vm.expectRevert(HCAFactory.HCAImplementationCannotBeZero.selector);
        vm.prank(owner);
        factory.setImplementationApproval(address(0), true);
    }

    function test_setImplementationApproval_revertsWhenNotOwner() external {
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner));
        vm.prank(nonOwner);
        factory.setImplementationApproval(address(implementation), true);
    }

    function test_setImplementation_revertsWhenImplementationNotApproved() external {
        vm.expectRevert(
            abi.encodeWithSelector(HCAFactory.HCAImplementationNotApproved.selector, address(implementation))
        );
        vm.prank(owner);
        factory.setImplementation(address(implementation));
    }

    function test_setImplementation_setsApprovedUpgradeTarget() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);

        vm.expectEmit(true, false, false, true, address(factory));
        emit HCAFactory.NewHCAImplementation(address(implementation));

        vm.prank(owner);
        factory.setImplementation(address(implementation));

        assertEq(factory.getImplementation(), address(implementation), "implementation");
    }

    function test_setImplementationApproval_revertsWhenRevokingCurrentImplementation() external {
        vm.startPrank(owner);
        factory.setImplementationApproval(address(implementation), true);
        factory.setImplementation(address(implementation));

        vm.expectRevert(
            abi.encodeWithSelector(HCAFactory.CannotRevokeCurrentHCAImplementation.selector, address(implementation))
        );
        factory.setImplementationApproval(address(implementation), false);
        vm.stopPrank();
    }

    function test_createAccount_revertsWhenImplementationNotApproved() external {
        vm.expectRevert(
            abi.encodeWithSelector(HCAFactory.HCAImplementationNotApproved.selector, address(implementation))
        );
        vm.prank(user);
        factory.createAccount(address(implementation), initData);
    }

    function test_createAccount_recordsMsgSenderAsOwner() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);

        address predicted = factory.computeAccountAddress(user);
        vm.expectEmit(true, true, true, true, address(factory));
        emit HCAFactory.AccountCreated(user, predicted, address(implementation));

        vm.prank(user);
        address hca = factory.createAccount(address(implementation), initData);

        assertEq(hca, predicted, "hca");
        assertEq(factory.getAccountOwner(hca), user, "hca owner");
        assertGt(hca.code.length, 0, "hca code");
    }

    function test_createAccount_forwardsValueWhenAccountAlreadyExists() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);
        vm.deal(user, 1 ether);

        vm.prank(user);
        address hca = factory.createAccount{value: 0.1 ether}(address(implementation), initData);
        assertEq(hca.balance, 0.1 ether, "initial balance");

        vm.prank(user);
        address sameHca = factory.createAccount{value: 0.2 ether}(address(implementation), initData);

        assertEq(sameHca, hca, "same hca");
        assertEq(hca.balance, 0.3 ether, "forwarded balance");
        assertEq(factory.getAccountOwner(hca), user, "hca owner");
    }

    function test_setAccount_designatesExistingApprovedAccount() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);
        MockSCA sca = new MockSCA(address(implementation));

        vm.expectEmit(true, true, true, true, address(factory));
        emit HCAFactory.AccountDesignated(user, address(sca), address(implementation));

        vm.prank(user);
        factory.setAccount(address(sca));

        assertEq(factory.getAccountOwner(address(sca)), user, "hca owner");
    }

    function test_setAccount_revertsWhenAccountIsZero() external {
        vm.expectRevert(HCAFactory.HCAAccountCannotBeZero.selector);
        vm.prank(user);
        factory.setAccount(address(0));
    }

    function test_setAccount_revertsWhenAccountHasNoCode() external {
        address sca = makeAddr("sca");

        vm.expectRevert(abi.encodeWithSelector(HCAFactory.HCAAccountHasNoCode.selector, sca));
        vm.prank(user);
        factory.setAccount(sca);
    }

    function test_setAccount_revertsWhenImplementationNotApproved() external {
        MockSCA sca = new MockSCA(address(implementation));

        vm.expectRevert(
            abi.encodeWithSelector(HCAFactory.HCAImplementationNotApproved.selector, address(implementation))
        );
        vm.prank(user);
        factory.setAccount(address(sca));
    }

    function test_setAccount_revertsWhenAccountAlreadyDesignated() external {
        vm.prank(owner);
        factory.setImplementationApproval(address(implementation), true);
        MockSCA sca = new MockSCA(address(implementation));

        vm.prank(user);
        factory.setAccount(address(sca));

        vm.expectRevert(abi.encodeWithSelector(HCAFactory.HCAAccountAlreadyDesignated.selector, address(sca), user));
        vm.prank(nonOwner);
        factory.setAccount(address(sca));
    }
}
