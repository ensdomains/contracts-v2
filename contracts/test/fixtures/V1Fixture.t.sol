// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    PARENT_CANNOT_CONTROL,
    CANNOT_UNWRAP,
    CANNOT_BURN_FUSES,
    LabelTooShort,
    LabelTooLong
} from "@ens/contracts/wrapper/NameWrapper.sol";

import {V1Fixture, NameCoder} from "./V1Fixture.sol";

// TODO: add more NameWrapper quirks and invariant tests.
contract V1FixtureTest is V1Fixture {
    function setUp() external {
        deployV1Fixture();
    }

    ////////////////////////////////////////////////////////////////////////
    // Deployment Helpers
    ////////////////////////////////////////////////////////////////////////

    function test_registerUnwrapped() external {
        (, uint256 tokenId) = registerUnwrapped("test");
        assertEq(ethRegistrarV1.ownerOf(tokenId), user, "owner");
    }

    function test_registerWrappedETH2LD() external {
        bytes memory name = registerWrappedETH2LD("test", 0);
        assertEq(nameWrapper.ownerOf(uint256(NameCoder.namehash(name, 0))), user, "owner");
    }

    function test_registerWrappedETH3LD() external {
        bytes memory parentName = registerWrappedETH2LD("test", 0);
        bytes memory name = createWrappedChild(parentName, "sub", 0);
        assertEq(nameWrapper.ownerOf(uint256(NameCoder.namehash(name, 0))), user, "owner");
    }

    function test_registerWrappedDNS2LD() external {
        bytes memory name = createWrappedName("ens.domains", 0);
        assertEq(nameWrapper.ownerOf(uint256(NameCoder.namehash(name, 0))), user, "owner");
    }

    function test_registerWrappedDNS3LD() external {
        bytes memory parentName = createWrappedName("ens.domains", 0);
        bytes memory name = createWrappedChild(parentName, "sub", 0);
        assertEq(nameWrapper.ownerOf(uint256(NameCoder.namehash(name, 0))), user, "owner");
    }

    function test_findResolverV1_unwrapped() external {
        (bytes memory name, ) = registerUnwrapped("test");
        assertEq(findResolverV1(name), address(0), "before");
        vm.prank(user);
        ensV1.setResolver(NameCoder.namehash(name, 0), address(1));
        assertEq(findResolverV1(name), address(1), "after");
    }

    function test_findResolverV1_wrapped() external {
        bytes memory name = createWrappedName("a.b.c", 0);
        assertEq(findResolverV1(name), address(0), "before");
        vm.prank(user);
        nameWrapper.setResolver(NameCoder.namehash(name, 0), address(1));
        assertEq(findResolverV1(name), address(1), "after");
    }

    ////////////////////////////////////////////////////////////////////////
    // NameWrapper Quirks
    ////////////////////////////////////////////////////////////////////////

    function test_nameWrapper_wrapRootReverts() external {
        vm.expectRevert(abi.encodeWithSignature("Error(string)", "readLabel: Index out of bounds"));
        nameWrapper.wrap(hex"00", address(1), address(0));
    }

    function test_nameWrapper_labelTooShort() external {
        bytes memory name = registerWrappedETH2LD("test", 0);
        vm.expectRevert(abi.encodeWithSelector(LabelTooShort.selector));
        vm.prank(user);
        nameWrapper.setSubnodeOwner(
            NameCoder.namehash(name, 0),
            "",
            user,
            0,
            uint64(block.timestamp + 1 days)
        );
    }

    function test_nameWraper_labelTooLong() external {
        bytes memory name = registerWrappedETH2LD("test", 0);
        string memory label = new string(256);
        vm.expectRevert(abi.encodeWithSelector(LabelTooLong.selector, label));
        vm.prank(user);
        nameWrapper.setSubnodeOwner(
            NameCoder.namehash(name, 0),
            label,
            user,
            0,
            uint64(block.timestamp + 1 days)
        );
    }

    function test_nameWrapper_expiryForETH2LDIncludesGrace() external {
        bytes memory name = registerWrappedETH2LD("test", 0);
        uint256 unwrappedExpiry = ethRegistrarV1.nameExpires(
            uint256(keccak256(bytes(NameCoder.firstLabel(name))))
        );
        (, , uint256 wrappedExpiry) = nameWrapper.getData(uint256(NameCoder.namehash(name, 0)));
        assertEq(unwrappedExpiry + ethRegistrarV1.GRACE_PERIOD(), wrappedExpiry);
    }

    function test_nameWrapper_CANNOT_UNWRAP_requires_PARENT_CANNOT_CONTROL() external {
        bytes memory name = registerWrappedETH2LD("test", CANNOT_UNWRAP);
        createWrappedChild(name, "1", PARENT_CANNOT_CONTROL);
        createWrappedChild(name, "2", PARENT_CANNOT_CONTROL | CANNOT_UNWRAP);
        vm.expectRevert();
        this.createWrappedChild(name, "3", CANNOT_UNWRAP);
    }

    function test_nameWrapper_PARENT_CANNOT_CONTROL_via_setFuses() external {
        bytes memory name = registerWrappedETH2LD("test", 0);
        (bytes32 labelhash, ) = NameCoder.readLabel(name, 0);
        vm.startPrank(user);
        nameWrapper.setFuses(NameCoder.namehash(name, 0), uint16(PARENT_CANNOT_CONTROL));
        nameWrapper.unwrapETH2LD(labelhash, user, user);
        vm.stopPrank();
    }

    function test_nameWrapper_PARENT_CANNOT_CONTROL_via_wrap() external {
        bytes memory parentName = registerWrappedETH2LD("test", CANNOT_UNWRAP);
        bytes memory name = createWrappedChild(parentName, "sub", PARENT_CANNOT_CONTROL);
        (bytes32 labelhash, ) = NameCoder.readLabel(name, 0);
        vm.startPrank(user);
        nameWrapper.setFuses(NameCoder.namehash(name, 0), uint16(PARENT_CANNOT_CONTROL));
        nameWrapper.unwrap(NameCoder.namehash(parentName, 0), labelhash, user);
        vm.stopPrank();
    }

    function test_nameWrapper_CANNOT_BURN_FUSES_via_wrap() external {
        registerWrappedETH2LD("test", CANNOT_UNWRAP | CANNOT_BURN_FUSES);
    }

    function test_nameWrapper_CANNOT_BURN_FUSES_via_setFuses() external {
        bytes memory name = registerWrappedETH2LD("test", CANNOT_UNWRAP);
        vm.prank(user);
        nameWrapper.setFuses(NameCoder.namehash(name, 0), uint16(CANNOT_BURN_FUSES));
    }

    function test_nameWrapper_CANNOT_BURN_FUSES_via_setChildFuses() external {
        bytes memory parentName = registerWrappedETH2LD("test", CANNOT_UNWRAP);
        bytes memory name = createWrappedChild(
            parentName,
            "sub",
            CANNOT_UNWRAP | PARENT_CANNOT_CONTROL
        );
        // setChildFuses() does not allow fuse changes if PCC
        // _setFuses() requires CU + PCC if child fuses as burned
        vm.expectRevert();
        vm.prank(user);
        nameWrapper.setChildFuses(
            NameCoder.namehash(parentName, 0),
            keccak256(bytes(NameCoder.firstLabel(name))),
            CANNOT_BURN_FUSES,
            uint64(block.timestamp + 1 days)
        );
    }

    function test_ethRegistrarV1_ownerOf_unregisteredReverts() external {
        vm.expectRevert();
        ethRegistrarV1.ownerOf(0);
    }
}
