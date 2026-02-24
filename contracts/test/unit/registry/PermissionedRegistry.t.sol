// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Vm, Test} from "forge-std/Test.sol";

import {IERC1155Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {
    PermissionedRegistry,
    IPermissionedRegistry,
    IEnhancedAccessControl,
    IRegistry,
    IStandardRegistry,
    IRegistryMetadata,
    IHCAFactoryBasic,
    EACBaseRolesLib,
    RegistryRolesLib,
    NameCoder,
    LibLabel
} from "~src/registry/PermissionedRegistry.sol";
import {SimpleRegistryMetadata} from "~src/registry/SimpleRegistryMetadata.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract PermissionedRegistryTest is Test, ERC1155Holder {
    MockPermissionedRegistry registry;
    MockHCAFactoryBasic hcaFactory;
    IRegistryMetadata metadata;

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address actor = makeAddr("actor");

    address testOwner = user1;
    string testLabel = "test";
    uint256 testRoles = 0;
    address testResolver = makeAddr("resolver");
    uint64 testExpiry = uint64(block.timestamp + 1000);
    IRegistry testRegistry = IRegistry(makeAddr("registry"));

    function setUp() public {
        hcaFactory = new MockHCAFactoryBasic();
        metadata = new SimpleRegistryMetadata(hcaFactory);
        registry = new MockPermissionedRegistry(
            hcaFactory,
            metadata,
            address(this),
            EACBaseRolesLib.ALL_ROLES
        );
    }

    function test_constructor() external view {
        assertTrue(registry.hasRootRoles(EACBaseRolesLib.ALL_ROLES, address(this)));
    }

    ////////////////////////////////////////////////////////////////////////
    // register()
    ////////////////////////////////////////////////////////////////////////

    function test_register() external {
        uint256 labelId = LibLabel.id(testLabel);
        uint256 expectedTokenId = LibLabel.withVersion(labelId, 0);
        vm.expectEmit();
        emit IRegistry.NameRegistered(
            expectedTokenId,
            bytes32(labelId),
            testLabel,
            testOwner,
            testExpiry,
            address(this)
        );
        vm.expectEmit();
        emit IERC1155.TransferSingle(address(this), address(0), testOwner, expectedTokenId, 1);
        vm.expectEmit();
        emit IPermissionedRegistry.TokenResource(expectedTokenId, expectedTokenId);
        vm.expectEmit();
        emit IRegistry.SubregistryUpdated(expectedTokenId, testRegistry, address(this));
        vm.expectEmit();
        emit IRegistry.ResolverUpdated(expectedTokenId, testResolver, address(this));
        uint256 tokenId = this._register();
        assertEq(registry.getExpiry(tokenId), testExpiry, "expiry");
        assertEq(registry.ownerOf(tokenId), testOwner, "owner");
        assertEq(registry.getResolver(testLabel), testResolver, "resolver");
        assertEq(address(registry.getSubregistry(testLabel)), address(testRegistry), "registry");
        assertTrue(registry.hasRoles(tokenId, testRoles, testOwner), "roles");
    }

    function test_register_expired() external {
        this._register();
        vm.warp(testExpiry);
        testExpiry += testExpiry;
        this._register();
    }

    // is this needed?
    function test_register_roles(uint16 compactRoles) external {
        testRoles = _expandRoles(compactRoles);
        assertTrue(registry.hasRoles(this._register(), testRoles, testOwner));
    }

    function test_register_withNullResolver() external {
        testResolver = address(0);
        vm.recordLogs();
        this._register();
        _expectNoEmit(vm.getRecordedLogs(), IRegistry.ResolverUpdated.selector);
    }

    function test_register_withNullRegistry() external {
        testRegistry = IRegistry(address(0));
        vm.recordLogs();
        this._register();
        _expectNoEmit(vm.getRecordedLogs(), IRegistry.SubregistryUpdated.selector);
    }

    function test_register_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_REGISTRAR,
                actor
            )
        );
        vm.prank(actor);
        this._register();
        // retry with permissions
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, actor);
        vm.prank(actor);
        this._register();
    }

    function test_register_cannotSetPastExpiration() external {
        testExpiry = 0;
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.CannotSetPastExpiration.selector, testExpiry)
        );
        this._register();
    }

    function test_register_tooShort() external {
        testLabel = "";
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsEmpty.selector));
        this._register();
    }

    function test_register_tooLong() external {
        testLabel = new string(256);
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsTooLong.selector, testLabel));
        this._register();
    }

    function test_register_alreadyRegistered() external {
        this._register();
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.NameAlreadyRegistered.selector, testLabel)
        );
        this._register();
    }

    ////////////////////////////////////////////////////////////////////////
    // reserve() == register() with null owner
    ////////////////////////////////////////////////////////////////////////

    function test_reserve() external {
        vm.expectEmit();
        emit IRegistry.NameReserved(
            LibLabel.withVersion(LibLabel.id(testLabel), 0),
            bytes32(LibLabel.id(testLabel)),
            testLabel,
            testExpiry,
            address(this)
        );
        uint256 tokenId = this._reserve();
        IPermissionedRegistry.State memory state = registry.getState(tokenId);
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.RESERVED), "reserved");
        assertEq(state.latestOwner, address(0), "owner");
        assertEq(state.expiry, testExpiry, "expiry");
        assertEq(registry.getResolver(testLabel), testResolver, "resolver");
        assertEq(address(registry.getSubregistry(testLabel)), address(0), "registry");
    }

    function test_reserve_alreadyReserved() external {
        this._reserve();
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, actor);
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionedRegistry.NameAlreadyReserved.selector, testLabel)
        );
        this._reserve();
    }

    function test_reserve_alreadyRegistered() external {
        this._register();
        registry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RESERVE_REGISTRAR,
            actor
        );
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.NameAlreadyRegistered.selector, testLabel)
        );
        vm.prank(actor);
        this._reserve();
    }

    function test_reserve_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_REGISTRAR,
                actor
            )
        );
        vm.prank(actor);
        this._reserve();
        // retry with permissions
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, actor);
        vm.prank(actor);
        this._reserve();
    }

    function test_reserve_withRoles() external {
        testRoles = RegistryRolesLib.ROLE_SET_RESOLVER;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                registry.ROOT_RESOURCE(),
                testRoles,
                address(this)
            )
        );
        this._reserve();
    }

    function test_reserve_then_register() external {
        this._reserve();
        this._register();
    }

    function test_reserve_then_register_notAuthorized() external {
        this._reserve();
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, actor); // insufficient
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_RESERVE_REGISTRAR,
                actor
            )
        );
        vm.prank(actor);
        this._register();
        // retry with permissions
        registry.grantRootRoles(RegistryRolesLib.ROLE_RESERVE_REGISTRAR, actor);
        vm.prank(actor);
        this._register();
    }

    ////////////////////////////////////////////////////////////////////////
    // renew()
    ////////////////////////////////////////////////////////////////////////

    function test_renew_registered() external {
        uint256 tokenId = this._register();
        ++testExpiry;
        vm.expectEmit();
        emit IRegistry.ExpiryUpdated(tokenId, testExpiry, address(this));
        registry.renew(tokenId, testExpiry);
        assertEq(registry.getExpiry(tokenId), testExpiry);
    }

    function test_renew_reserved() external {
        uint256 tokenId = this._reserve();
        ++testExpiry;
        registry.renew(tokenId, testExpiry);
        assertEq(registry.getExpiry(tokenId), testExpiry);
    }

    function test_renew_available() external {
        uint256 tokenId = registry.getTokenId(LibLabel.id(testLabel));
        vm.expectRevert(abi.encodeWithSelector(IStandardRegistry.NameExpired.selector, tokenId));
        registry.renew(tokenId, testExpiry);
    }

    function test_renew_expired() external {
        uint256 tokenId = this._register();
        vm.warp(testExpiry);
        testExpiry += testExpiry;
        vm.expectRevert(abi.encodeWithSelector(IStandardRegistry.NameExpired.selector, tokenId));
        registry.renew(tokenId, testExpiry);
    }

    function test_renew_notAuthorized() external {
        uint256 tokenId = this._register();
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_RENEW,
                actor
            )
        );
        vm.prank(actor);
        registry.renew(tokenId, testExpiry);
        // retry with permissions
        registry.grantRootRoles(RegistryRolesLib.ROLE_RENEW, actor);
        vm.prank(actor);
        registry.renew(tokenId, testExpiry);
    }

    function test_renew_cannotReduceExpiration() external {
        uint256 tokenId = this._register();
        testExpiry -= 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStandardRegistry.CannotReduceExpiration.selector,
                testExpiry + 1,
                testExpiry
            )
        );
        registry.renew(tokenId, testExpiry);
    }

    function test_renew_self() external {
        testRoles = RegistryRolesLib.ROLE_RENEW;
        uint256 tokenId = this._register();
        vm.prank(testOwner);
        registry.renew(tokenId, testExpiry);
    }

    function test_renew_self_notAuthorized() external {
        uint256 tokenId = this._register();
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_RENEW,
                testOwner
            )
        );
        vm.prank(testOwner);
        registry.renew(tokenId, testExpiry);
        // retry with permissions
        registry.grantRoles(tokenId, RegistryRolesLib.ROLE_RENEW, actor);
        vm.prank(actor);
        registry.renew(tokenId, testExpiry);
    }

    ////////////////////////////////////////////////////////////////////////
    // unregister()
    ////////////////////////////////////////////////////////////////////////

    function test_unregister_available() external {
        uint256 tokenId = registry.getTokenId(LibLabel.id(testLabel));
        vm.expectRevert(abi.encodeWithSelector(IStandardRegistry.NameExpired.selector, tokenId));
        registry.unregister(tokenId);
    }

    function test_unregister_registered() external {
        uint256 tokenId = this._register();
        vm.expectEmit();
        emit IRegistry.NameUnregistered(tokenId, address(this));
        vm.expectEmit();
        emit IERC1155.TransferSingle(address(this), testOwner, address(0), tokenId, 1);
        registry.unregister(tokenId);
        assertEq(
            uint8(registry.getState(tokenId).status),
            uint8(IPermissionedRegistry.Status.AVAILABLE),
            "status"
        );
        assertEq(registry.ownerOf(tokenId), address(0), "owner");
        assertEq(registry.getExpiry(tokenId), block.timestamp, "expiry");
        assertEq(registry.getResolver(testLabel), address(0), "resolver");
        assertEq(address(registry.getSubregistry(testLabel)), address(0), "subregistry");
    }

    function test_unregister_reserved() external {
        uint256 tokenId = this._reserve();
        vm.recordLogs();
        vm.expectEmit();
        emit IRegistry.NameUnregistered(tokenId, address(this));
        registry.unregister(tokenId);
        _expectNoEmit(vm.getRecordedLogs(), IERC1155.TransferSingle.selector);
    }

    function test_unregister_self() external {
        testRoles = RegistryRolesLib.ROLE_UNREGISTER;
        uint256 tokenId = this._register();
        vm.prank(testOwner);
        registry.unregister(tokenId);
    }

    function test_unregister_notAuthorized() external {
        uint256 tokenId = this._register();
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                tokenId,
                RegistryRolesLib.ROLE_UNREGISTER,
                actor
            )
        );
        vm.prank(actor);
        registry.unregister(tokenId);
        // retry with permissions
        registry.grantRootRoles(RegistryRolesLib.ROLE_UNREGISTER, actor);
        vm.prank(actor);
        registry.unregister(tokenId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Transitions that require multiple actions
    ////////////////////////////////////////////////////////////////////////

    // REGISTERED => REGISTERED
    function test_register_then_register() external {
        uint256 tokenId = this._register();
        registry.unregister(tokenId); // #1
        this._register(); // #2
    }

    // REGISTERED => RESERVED
    function test_register_then_reserve() external {
        uint256 tokenId = this._register();
        registry.unregister(tokenId); // #1
        this._reserve(); // #2
    }

    // RESERVED => RESERVED
    function test_reserve_then_reserve() external {
        uint256 tokenId = this._reserve();
        registry.unregister(tokenId); // #1
        --testExpiry;
        this._reserve(); // #2
    }

    ////////////////////////////////////////////////////////////////////////
    // setSubregistry() and getSubregistry()
    ////////////////////////////////////////////////////////////////////////

    function test_setSubregistry() external {
        testRoles = RegistryRolesLib.ROLE_SET_SUBREGISTRY;
        uint256 tokenId = this._register();
        vm.expectEmit();
        emit IRegistry.SubregistryUpdated(tokenId, testRegistry, testOwner);
        vm.prank(testOwner);
        registry.setSubregistry(tokenId, testRegistry);
        vm.assertEq(address(registry.getSubregistry(testLabel)), address(testRegistry));
        vm.warp(testExpiry);
        vm.assertEq(address(registry.getSubregistry(testLabel)), address(0), "after");
    }

    function test_setSubregistry_asRoot() external {
        uint256 tokenId = this._register();
        vm.expectRevert();
        vm.prank(testOwner);
        registry.setSubregistry(tokenId, testRegistry);
        // retry with permissions
        registry.setSubregistry(tokenId, testRegistry);
    }

    function test_setSubregistry_whileReserved() external {
        uint256 tokenId = this._reserve();
        registry.setSubregistry(tokenId, testRegistry);
    }

    function test_setSubregistry_notAuthorized() external {
        uint256 tokenId = this._register();
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_SET_SUBREGISTRY,
                testOwner
            )
        );
        vm.prank(testOwner);
        registry.setSubregistry(tokenId, testRegistry);
        // retry with permissions
        registry.grantRoles(tokenId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, testOwner);
        vm.prank(testOwner);
        registry.setSubregistry(tokenId, testRegistry);
    }

    ////////////////////////////////////////////////////////////////////////
    // setResolver() and getResolver()
    ////////////////////////////////////////////////////////////////////////

    function test_setResolver() external {
        testRoles = RegistryRolesLib.ROLE_SET_RESOLVER;
        uint256 tokenId = this._register();
        vm.expectEmit();
        emit IRegistry.ResolverUpdated(tokenId, testResolver, testOwner);
        vm.prank(testOwner);
        registry.setResolver(tokenId, testResolver);
        vm.assertEq(registry.getResolver(testLabel), testResolver, "before");
        vm.warp(testExpiry);
        vm.assertEq(registry.getResolver(testLabel), address(0), "after");
    }

    function test_setResolver_asRoot() external {
        uint256 tokenId = this._register();
        vm.expectRevert();
        vm.prank(testOwner);
        registry.setResolver(tokenId, testResolver);
        // retry with permissions
        registry.setResolver(tokenId, testResolver);
    }

    function test_setResolver_whileReserved() external {
        uint256 tokenId = this._reserve();
        registry.setResolver(tokenId, testResolver);
    }

    function test_setResolver_notAuthorized() external {
        uint256 tokenId = this._register();
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_SET_RESOLVER,
                testOwner
            )
        );
        vm.prank(testOwner);
        registry.setResolver(tokenId, testResolver);
        // retry with permissions
        registry.grantRoles(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, testOwner);
        vm.prank(testOwner);
        registry.setResolver(tokenId, testResolver);
    }

    ////////////////////////////////////////////////////////////////////////
    // ERC-1155 (operations require exact tokenId)
    ////////////////////////////////////////////////////////////////////////

    function test_ownerOf() external {
        assertEq(registry.ownerOf(0), address(0), "dne");
        uint256 tokenId = this._register();
        assertEq(registry.ownerOf(tokenId), testOwner, "exact");
        assertEq(registry.ownerOf(tokenId + 1), address(0), "+1");
    }

    // cleared after burn
    function test_latestOwnerOf() external {
        assertEq(registry.latestOwnerOf(0), address(0), "dne");
        uint256 tokenId = this._register();
        assertEq(registry.latestOwnerOf(tokenId), testOwner, "registered");
        registry.unregister(tokenId);
        assertEq(registry.latestOwnerOf(tokenId), address(0), "unregistered");
        tokenId = this._register();
        vm.warp(testExpiry);
        assertEq(registry.latestOwnerOf(tokenId), testOwner, "expired");
    }

    function test_safeTransferFrom() external {
        testRoles = RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = this._register();
        vm.prank(user1);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");
    }

    function test_safeTransferFrom_notAuthorized() external {
        uint256 tokenId = this._register();
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.TransferDisallowed.selector, tokenId, user1)
        );
        vm.prank(user1);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");
    }

    function test_safeTransferFrom_notAuthorized_setApprovalForAll() external {
        uint256 tokenId = this._register();
        vm.prank(user1);
        registry.setApprovalForAll(user2, true);
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.TransferDisallowed.selector, tokenId, user1)
        );
        vm.prank(user2);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");
    }

    function test_safeBatchTransferFrom() external {
        testRoles = RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = this._register();
        testLabel = "abc";
        tokenIds[1] = this._register();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;
        vm.prank(user1);
        registry.safeBatchTransferFrom(user1, user2, tokenIds, amounts, "");
    }

    function test_safeBatchTransferFrom_oneError() external {
        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = this._register(); // no transfer role
        testLabel = "abc";
        testRoles = RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        tokenIds[1] = this._register();
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(
                IStandardRegistry.TransferDisallowed.selector,
                tokenIds[0],
                user1
            )
        );
        vm.prank(user1);
        registry.safeBatchTransferFrom(user1, user2, tokenIds, amounts, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // getState()
    ////////////////////////////////////////////////////////////////////////

    function test_getState_available() external view {
        uint256 tokenId = registry.getTokenId(LibLabel.id(testLabel));
        IPermissionedRegistry.State memory state = registry.getState(tokenId);
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.AVAILABLE), "status");
        assertEq(state.expiry, 0, "expiry");
        assertEq(state.latestOwner, address(0), "owner");
        assertEq(state.tokenId, tokenId, "tokenId");
        assertEq(state.resource, tokenId + 1, "resource"); // next
        _checkStateGetters(state);
    }

    function test_getState_reserved() external {
        uint256 tokenId = this._reserve();
        IPermissionedRegistry.State memory state = registry.getState(tokenId);
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.RESERVED), "status");
        assertEq(state.expiry, testExpiry, "expiry");
        assertEq(state.latestOwner, address(0), "owner");
        assertEq(state.tokenId, tokenId, "tokenId");
        assertEq(state.resource, tokenId, "resource");
        _checkStateGetters(state);
    }

    function test_getState_registered() external {
        uint256 tokenId = this._register();
        IPermissionedRegistry.State memory state = registry.getState(tokenId);
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.REGISTERED), "status");
        assertEq(state.expiry, testExpiry, "expiry");
        assertEq(state.latestOwner, testOwner, "owner");
        assertEq(state.tokenId, tokenId, "tokenId");
        assertEq(state.resource, tokenId, "resource");
        _checkStateGetters(state);
    }

    function test_getState_expired() external {
        uint256 tokenId = this._register();
        vm.warp(testExpiry);
        IPermissionedRegistry.State memory state = registry.getState(tokenId);
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.AVAILABLE), "status");
        assertEq(state.expiry, testExpiry, "expiry");
        assertEq(state.latestOwner, testOwner, "owner");
        assertEq(state.tokenId, tokenId, "tokenId");
        assertEq(state.resource, tokenId + 1, "resource"); // next
        _checkStateGetters(state);
    }

    function test_getState_unregistered() external {
        uint256 tokenId = this._register();
        registry.unregister(tokenId);
        IPermissionedRegistry.State memory state = registry.getState(tokenId);
        assertEq(uint8(state.status), uint8(IPermissionedRegistry.Status.AVAILABLE), "status");
        assertEq(state.expiry, block.timestamp, "expiry");
        assertEq(state.latestOwner, address(0), "owner");
        assertEq(state.tokenId, tokenId + 1, "tokenId"); // burned
        assertEq(state.resource, tokenId + 2, "resource"); // next
        _checkStateGetters(state);
    }

    function _checkStateGetters(IPermissionedRegistry.State memory state) internal view {
        if (state.status != IPermissionedRegistry.Status.AVAILABLE) {
            assertEq(registry.ownerOf(state.tokenId), state.latestOwner, "ownerOf");
        }
        assertEq(registry.latestOwnerOf(state.tokenId), state.latestOwner, "latestOwnerOf");
        assertEq(registry.getExpiry(state.tokenId), state.expiry, "getExpiry");
        assertEq(registry.getTokenId(state.tokenId), state.tokenId, "getTokenId");
        assertEq(registry.getResource(state.tokenId), state.resource, "getResource");
        assertEq(uint8(registry.getStatus(state.tokenId)), uint8(state.status), "getStatus");
    }

    ////////////////////////////////////////////////////////////////////////
    // anyId
    ////////////////////////////////////////////////////////////////////////

    function test_renew_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        registry.renew(LibLabel.withVersion(tokenId, version), testExpiry + 1);
    }

    function test_unregister_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        registry.unregister(LibLabel.withVersion(tokenId, version));
    }

    function test_setSubregistry_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        registry.setSubregistry(LibLabel.withVersion(tokenId, version), testRegistry);
    }

    function test_setResolver_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        registry.setResolver(LibLabel.withVersion(tokenId, version), testResolver);
    }

    function test_getExpiry_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        assertEq(registry.getExpiry(LibLabel.withVersion(tokenId, version)), testExpiry);
    }

    function test_getStatus_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        assertEq(
            uint8(registry.getStatus(LibLabel.withVersion(tokenId, version))),
            uint8(IPermissionedRegistry.Status.REGISTERED)
        );
    }

    function test_getState_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        assertEq(registry.getState(LibLabel.withVersion(tokenId, version)).tokenId, tokenId);
    }

    function test_getTokenId_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        assertEq(registry.getTokenId(LibLabel.withVersion(tokenId, version)), tokenId);
    }

    function test_getResource_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        assertEq(
            registry.getResource(LibLabel.withVersion(tokenId, version)),
            registry.getResource(tokenId)
        );
    }

    function test_getResource_rootNeverExpires() external view {
        assertEq(registry.getResource(registry.ROOT_RESOURCE()), registry.ROOT_RESOURCE());
    }

    function test_grantRoles_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        registry.grantRoles(
            LibLabel.withVersion(tokenId, version),
            RegistryRolesLib.ROLE_RENEW,
            user2
        );
    }

    function test_revokeRoles_anyId(uint32 version) external {
        uint256 tokenId = this._register();
        registry.revokeRoles(
            LibLabel.withVersion(tokenId, version),
            RegistryRolesLib.ROLE_RENEW,
            user2
        );
    }

    function test_roles_anyId(uint32 version) external {
        testRoles = EACBaseRolesLib.ALL_ROLES;
        uint256 tokenId = this._register();
        assertEq(registry.roles(LibLabel.withVersion(tokenId, version), testOwner), testRoles);
    }

    function test_roleCount_anyId(uint32 version) external {
        testRoles = EACBaseRolesLib.ALL_ROLES;
        uint256 tokenId = this._register();
        assertEq(registry.roleCount(LibLabel.withVersion(tokenId, version)), testRoles);
    }

    function test_hasRoles_anyId(uint32 version) external {
        testRoles = EACBaseRolesLib.ALL_ROLES;
        uint256 tokenId = this._register();
        assertTrue(registry.hasRoles(LibLabel.withVersion(tokenId, version), testRoles, testOwner));
    }

    function test_hasAssignees_anyId(uint32 version) external {
        testRoles = EACBaseRolesLib.ALL_ROLES;
        uint256 tokenId = this._register();
        assertTrue(registry.hasAssignees(LibLabel.withVersion(tokenId, version), testRoles));
    }

    function test_getAssigneeCount_anyId(uint32 version) external {
        testRoles = EACBaseRolesLib.ALL_ROLES;
        uint256 tokenId = this._register();
        (uint256 counts, ) = registry.getAssigneeCount(
            LibLabel.withVersion(tokenId, version),
            testRoles
        );
        assertEq(counts, testRoles);
    }

    ////////////////////////////////////////////////////////////////////////
    // Token Regeneration
    ////////////////////////////////////////////////////////////////////////

    function test_regenerate_mintBurn() external {
        IPermissionedRegistry.State memory s0 = registry.getState(this._register());
        registry.unregister(s0.tokenId);
        IPermissionedRegistry.State memory s1 = registry.getState(this._register());
        registry.unregister(s1.tokenId);
        IPermissionedRegistry.State memory s2 = registry.getState(this._register());
        registry.unregister(s2.tokenId);
        assertEq(s0.tokenId + 1, s1.tokenId, "token:01");
        assertEq(s0.resource + 1, s1.resource, "resource:01");
        assertEq(s1.tokenId + 1, s2.tokenId, "token:12");
        assertEq(s1.resource + 1, s2.resource, "resource:12");
    }

    function test_regenerate_safeTransferFrom(uint16 compactRoles) external {
        testRoles = RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN | _expandRoles(compactRoles);
        uint256 tokenId = this._register();
        IPermissionedRegistry.State memory s0 = registry.getState(tokenId);
        assertEq(s0.latestOwner, user1, "before:owner");
        assertTrue(registry.hasRoles(tokenId, testRoles, user1), "before:user1");
        assertFalse(registry.hasRoles(tokenId, testRoles, user2), "before:user2");
        vm.prank(user1);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");
        IPermissionedRegistry.State memory s1 = registry.getState(tokenId);
        assertEq(s1.latestOwner, user2, "after:owner");
        assertFalse(registry.hasRoles(tokenId, testRoles, user1), "after:user1");
        assertTrue(registry.hasRoles(tokenId, testRoles, user2), "after:user2");
        assertEq(s0.tokenId, s1.tokenId, "token"); // unchanged
        assertEq(s0.resource, s1.resource, "resource"); // unchanged
    }

    function test_regenerate_eac() external {
        IPermissionedRegistry.State memory s0 = registry.getState(this._register());
        registry.grantRoles(s0.tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, user2); // regen
        IPermissionedRegistry.State memory s1 = registry.getState(s0.tokenId);
        registry.revokeRoles(s0.tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, user2); // regen
        IPermissionedRegistry.State memory s2 = registry.getState(s0.tokenId);
        assertEq(s0.tokenId + 1, s1.tokenId, "token:01");
        assertEq(s0.resource, s1.resource, "resource:01");
        assertEq(s0.latestOwner, s1.latestOwner, "owner:01");
        assertEq(s1.tokenId + 1, s2.tokenId, "token:12");
        assertEq(s1.resource, s2.resource, "resource:12");
        assertEq(s1.latestOwner, s2.latestOwner, "owner:12");
    }

    ////////////////////////////////////////////////////////////////////////
    // Specific Cases
    ////////////////////////////////////////////////////////////////////////

    // scenerio:
    // 1. user2 buys token from an exchange from user1
    // 2. user1 detects and frontruns a revoke() that cripples the token
    // 3. user2 receives crippled token => angry!
    function test_transferAbortsAfterRevoke() external {
        testRoles =
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN |
            RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN;
        uint256 tokenId = this._register();
        // make token available for sale
        vm.prank(user1);
        registry.setApprovalForAll(actor, true);
        // step #1: user2 buys token
        // => transaction detected in mempool
        // step #2: front-run
        vm.prank(user1);
        registry.revokeRoles(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN, user1);
        // token has now regenerated
        uint256 newTokenId = registry.getTokenId(tokenId);
        assertNotEq(tokenId, newTokenId, "regen");
        // step #3: safeTransferFrom() executes and fails
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC1155Errors.ERC1155InsufficientBalance.selector,
                user1,
                0,
                1,
                tokenId
            )
        );
        vm.prank(actor);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");
    }

    // scenerio: BET-430
    // 1. token has max assignees (15)
    // 2. transfer needs to transferRoles without blowing up
    function test_transferWithMaxAssignees() external {
        testRoles = RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = this._register();
        // step #1: fill assignees
        for (uint256 i; i <= 14; ++i) {
            registry.grantRoles(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, address(uint160(~i)));
        }
        vm.expectRevert();
        registry.grantRoles(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, user2); // => max assignees
        tokenId = registry.getTokenId(tokenId); // token has regenerated
        // step #2: transfer doesn't fail
        vm.prank(user1);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // Internals
    ////////////////////////////////////////////////////////////////////////

    // only changes on burn, grant, or revoke
    function test_tokenVersionId() external {
        uint256 tokenId = LibLabel.id(testLabel);
        assertEq(registry.getEntry(tokenId).tokenVersionId, 0, "dne");
        tokenId = this._register();
        assertEq(registry.getEntry(tokenId).tokenVersionId, 0, "register");
        vm.warp(testExpiry);
        testExpiry += testExpiry;
        assertEq(registry.getEntry(tokenId).tokenVersionId, 0, "expired");
        tokenId = this._register(); // here
        assertEq(registry.getEntry(tokenId).tokenVersionId, 1, "reregister");
        registry.grantRoles(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, user2); // here
        assertEq(registry.getEntry(tokenId).tokenVersionId, 2, "grant");
        registry.revokeRoles(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, user2); // here
        assertEq(registry.getEntry(tokenId).tokenVersionId, 3, "revoke");
        registry.unregister(tokenId); // here
        assertEq(registry.getEntry(tokenId).tokenVersionId, 4, "unregistered");
    }

    // only changes after burn
    function test_eacVersionId() external {
        uint256 tokenId = LibLabel.id(testLabel);
        assertEq(registry.getEntry(tokenId).eacVersionId, 0, "dne");
        tokenId = this._register();
        assertEq(registry.getEntry(tokenId).eacVersionId, 0, "register");
        vm.warp(testExpiry);
        testExpiry += testExpiry;
        assertEq(registry.getEntry(tokenId).eacVersionId, 0, "expired");
        tokenId = this._register(); // here
        assertEq(registry.getEntry(tokenId).eacVersionId, 1, "reregister");
        registry.grantRoles(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, user2);
        assertEq(registry.getEntry(tokenId).eacVersionId, 1, "grant");
        registry.revokeRoles(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER, user2);
        assertEq(registry.getEntry(tokenId).eacVersionId, 1, "revoke");
        registry.unregister(tokenId); // here
        assertEq(registry.getEntry(tokenId).eacVersionId, 2, "unregistered");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _register() external returns (uint256) {
        vm.prank(msg.sender); // propagate
        return
            registry.register(
                testLabel,
                testOwner,
                testRegistry,
                testResolver,
                testRoles,
                testExpiry
            );
    }

    function _reserve() external returns (uint256) {
        vm.prank(msg.sender); // propagate
        return
            registry.register(
                testLabel,
                address(0),
                IRegistry(address(0)),
                testResolver,
                testRoles,
                testExpiry
            );
    }

    function _expectNoEmit(Vm.Log[] memory logs, bytes32 topic0) internal pure {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic0) {
                revert(string.concat("found unexpected event: ", vm.toString(topic0)));
            }
        }
    }

    function _expandRoles(uint16 compactRoles) internal pure returns (uint256 roles) {
        for (uint256 i; i < 16; ++i) {
            if ((compactRoles & (1 << i)) != 0) {
                roles |= (1 << (i << 2));
            }
        }
    }
}

contract MockPermissionedRegistry is PermissionedRegistry {
    constructor(
        IHCAFactoryBasic hcaFactory,
        IRegistryMetadata metadata,
        address ownerAddress,
        uint256 ownerRoles
    ) PermissionedRegistry(hcaFactory, metadata, ownerAddress, ownerRoles) {}
    function getEntry(uint256 anyId) external view returns (PermissionedRegistry.Entry memory) {
        return _entry(anyId);
    }
}
