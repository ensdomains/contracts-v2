// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {ApprovedUpgradeGate} from "~src/registry/ApprovedUpgradeGate.sol";

contract ApprovedUpgradeGateTest is Test {
    ApprovedUpgradeGate gate;

    address owner = makeAddr("owner");
    address nonOwner = makeAddr("nonOwner");
    address implementation = makeAddr("implementation");

    function setUp() public {
        gate = new ApprovedUpgradeGate(owner);
    }

    function test_constructor_setsOwner() external view {
        assertEq(gate.owner(), owner, "owner");
        assertFalse(gate.approvedImplementations(implementation), "implementation");
    }

    function test_setImplementationApproval_approvesImplementation() external {
        vm.expectEmit(true, true, false, true, address(gate));
        emit ApprovedUpgradeGate.ImplementationApprovalChanged(implementation, true);

        vm.prank(owner);
        gate.setImplementationApproval(implementation, true);

        assertTrue(gate.approvedImplementations(implementation), "implementation");
    }

    function test_setImplementationApproval_revokesImplementation() external {
        vm.prank(owner);
        gate.setImplementationApproval(implementation, true);

        vm.expectEmit(true, true, false, true, address(gate));
        emit ApprovedUpgradeGate.ImplementationApprovalChanged(implementation, false);

        vm.prank(owner);
        gate.setImplementationApproval(implementation, false);

        assertFalse(gate.approvedImplementations(implementation), "implementation");
    }

    function test_setImplementationApproval_revertsWhenNotOwner() external {
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner)
        );
        vm.prank(nonOwner);
        gate.setImplementationApproval(implementation, true);

        assertFalse(gate.approvedImplementations(implementation), "implementation");
    }
}
