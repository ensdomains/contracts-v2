// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {PermissionedAddressSet} from "~src/utils/PermissionedAddressSet.sol";
import {IHCA} from "~src/utils/interfaces/IHCA.sol";

abstract contract HCAFixture is Test {
    PermissionedAddressSet trustedHCASet;

    MockHCA trustedHCAImpl;
    MockHCA untrustedHCAImpl;
    MockRevertingHCA revertingHCAImpl;

    uint256 private nextSalt = 1;

    function deployHCAFixture() public {
        trustedHCASet = new PermissionedAddressSet(address(this));

        trustedHCAImpl = new MockHCA();
        untrustedHCAImpl = new MockHCA();
        revertingHCAImpl = new MockRevertingHCA();

        trustedHCASet.approve(address(trustedHCAImpl), true);
        trustedHCASet.approve(address(revertingHCAImpl), true);
    }

    function test_trustedHCASet() external view {
        assertTrue(trustedHCASet.includes(address(trustedHCAImpl)), "trusted");
        assertFalse(trustedHCASet.includes(address(untrustedHCAImpl)), "untrusted");
        assertTrue(trustedHCASet.includes(address(revertingHCAImpl)), "reverting");
    }

    function _deployHCA(IVerifiableFactory verifiableFactory, address hcaOwner, address hcaImpl)
        internal
        returns (address)
    {
        bytes memory data = abi.encodeCall(MockHCA.initialize, (hcaOwner));
        return verifiableFactory.deployProxy(hcaImpl, nextSalt++, data);
    }
}


contract MockHCA is IHCA {
    address internal _owner;
    function initialize(address owner_) external {
        _owner = owner_;
    }
    function owner() external view virtual returns (address) {
        return _owner;
    }
}


contract MockRevertingHCA is MockHCA {
    function owner() external pure override returns (address) {
        revert();
    }
}
