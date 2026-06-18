// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {IABIResolver} from "@ens/contracts/resolvers/profiles/IABIResolver.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IDNSRecordResolver} from "@ens/contracts/resolvers/profiles/IDNSRecordResolver.sol";
import {IDNSZoneResolver} from "@ens/contracts/resolvers/profiles/IDNSZoneResolver.sol";
import {IDataResolver} from "@ens/contracts/resolvers/profiles/IDataResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";
import {IInterfaceResolver} from "@ens/contracts/resolvers/profiles/IInterfaceResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {IPubkeyResolver} from "@ens/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";

import {PublicResolverV2} from "~src/resolver/PublicResolverV2.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {V1Fixture} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract PublicResolverV2Test is V1Fixture, V2Fixture {
    PublicResolverV2 publicResolver;

    address actor = makeAddr("actor");
    address friend = makeAddr("friend");

    function setUp() external {
        deployV1Fixture();
        deployV2Fixture();
        publicResolver = new PublicResolverV2(nameWrapper, rootRegistry, contractNamer);
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(
                address(publicResolver),
                type(IMulticallable).interfaceId
            ),
            "IMulticallable"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(publicResolver),
                type(IContractNamer).interfaceId
            ),
            "IContractNamer"
        );

        // profiles
        assertTrue(
            ERC165Checker.supportsInterface(address(publicResolver), type(IABIResolver).interfaceId),
            "IABIResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(publicResolver), type(IAddrResolver).interfaceId),
            "IAddrResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(publicResolver),
                type(IAddressResolver).interfaceId
            ),
            "IAddressResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(publicResolver),
                type(IContentHashResolver).interfaceId
            ),
            "IContentHashResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(publicResolver), type(IDataResolver).interfaceId),
            "IDataResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(publicResolver),
                type(IDNSRecordResolver).interfaceId
            ),
            "IDNSRecordResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(publicResolver),
                type(IDNSZoneResolver).interfaceId
            ),
            "IDNSZoneResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(publicResolver),
                type(IHasAddressResolver).interfaceId
            ),
            "IHasAddressResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(publicResolver),
                type(IInterfaceResolver).interfaceId
            ),
            "IInterfaceResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(publicResolver), type(INameResolver).interfaceId),
            "INameResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(publicResolver),
                type(IPubkeyResolver).interfaceId
            ),
            "IPubkeyResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(publicResolver), type(ITextResolver).interfaceId),
            "ITextResolver"
        );
    }

    function test_canModifyName() external {
        bytes32 node = _register("test");

        // call a setter
        vm.prank(testOwner);
        publicResolver.setAddr(node, testOwner);
    }

    function test_canModifyName_setApprovalForAll() external {
        bytes32 node = _register("test");

        vm.prank(testOwner);
        publicResolver.setApprovalForAll(friend, true);

        assertTrue(publicResolver.canModifyName(node, friend));

        // call a setter
        vm.prank(friend);
        publicResolver.setAddr(node, testOwner);
    }

    function test_canModifyName_approve() external {
        bytes32 node = _register("test");

        vm.prank(testOwner);
        publicResolver.approve(node, friend, true);

        assertTrue(publicResolver.canModifyName(node, friend));
        assertFalse(publicResolver.canModifyName(~node, friend));

        // call a setter
        vm.prank(friend);
        publicResolver.setAddr(node, testOwner);
    }

    function test_canModifyName_notAuthorized(bytes32 node) external {
        assertFalse(publicResolver.canModifyName(node, testOwner));

        // call a setter
        vm.expectRevert();
        vm.prank(actor);
        publicResolver.setAddr(node, testOwner);
    }

    ////////////////////////////////////////////////////////////////////////
    // Approval
    ////////////////////////////////////////////////////////////////////////

    function test_isApprovedForAll() external {
        assertFalse(publicResolver.isApprovedForAll(testOwner, friend));

        vm.expectEmit();
        emit PublicResolverV2.ApprovalForAll(testOwner, friend, true);
        vm.prank(testOwner);
        publicResolver.setApprovalForAll(friend, true);

        assertTrue(publicResolver.isApprovedForAll(testOwner, friend), "friend");
        assertFalse(publicResolver.isApprovedForAll(testOwner, actor), "actor");
    }

    function test_isApprovedFor(bytes32 node) external {
        assertFalse(publicResolver.isApprovedFor(testOwner, node, friend));

        vm.expectEmit();
        emit PublicResolverV2.Approved(testOwner, node, friend, true);
        vm.prank(testOwner);
        publicResolver.approve(node, friend, true);

        assertTrue(publicResolver.isApprovedFor(testOwner, node, friend), "friend");
        assertFalse(publicResolver.isApprovedFor(testOwner, ~node, friend), "other node");
        assertFalse(publicResolver.isApprovedFor(testOwner, node, actor), "other actor");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _register(string memory label) internal returns (bytes32 node) {
        // register wrapped name in v1
        bytes memory name = registerWrappedETH2LD(label, 0);
        node = NameCoder.namehash(name, 0);

        assertFalse(publicResolver.canModifyName(node, testOwner), "before");

        // register same name in v2
        ethRegistry.register(
            label,
            testOwner,
            IRegistry(address(0)),
            address(publicResolver),
            0,
            uint64(block.timestamp + 1 days)
        );

        assertTrue(publicResolver.canModifyName(node, testOwner), "after");
    }
}
