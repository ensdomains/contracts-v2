// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, Vm} from "forge-std/Test.sol";

import {LabelStore, ILabelStore, LibLabel, NameCoder} from "~src/utils/LabelStore.sol";

contract LabelStoreTest is Test {
    LabelStore labelStore;

    function setUp() external {
        labelStore = new LabelStore();
    }

    function test_setLabel(string calldata label, uint32 version) external {
        _assumeValidLabel(label);

        uint256 labelId = LibLabel.id(label);

        assertEq(labelStore.getLabel(LibLabel.withVersion(labelId, version)), "", "before");

        vm.expectEmit();
        emit ILabelStore.Label(bytes32(labelId), label);
        labelStore.setLabel(label);

        assertEq(labelStore.getLabel(LibLabel.withVersion(labelId, version)), label, "after");
    }

    function test_setLabel_again(string calldata label) external {
        _assumeValidLabel(label);

        labelStore.setLabel(label);

        vm.recordLogs();
        labelStore.setLabel(label);
        _expectNoEmit(vm.getRecordedLogs(), ILabelStore.Label.selector);
    }

    function test_setLabel_empty() external {
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsEmpty.selector));
        labelStore.setLabel("");
    }

    function test_setLabel_tooLong() external {
        string memory label = new string(256);
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsTooLong.selector, label));
        labelStore.setLabel(label);
    }

    function _assumeValidLabel(string memory label) internal pure {
        vm.assume(bytes(label).length > 0 && bytes(label).length < 256);
    }

    function _expectNoEmit(Vm.Log[] memory logs, bytes32 topic0) internal pure {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic0) {
                revert(string.concat("found unexpected event: ", vm.toString(topic0)));
            }
        }
    }
}
