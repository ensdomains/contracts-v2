// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Vm, Test} from "forge-std/Test.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IRegistryMetadata} from "~src/registry/interfaces/IRegistryMetadata.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {SimpleRegistryMetadata} from "~src/registry/SimpleRegistryMetadata.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {
    PermissionedRegistry,
    IPermissionedRegistry,
    IEnhancedAccessControl,
    IRegistry,
    IStandardRegistry
} from "~src/registry/PermissionedRegistry.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract PermissionedRegistryTest is Test, ERC1155Holder {
    event TransferSingle(
        address indexed operator,
        address indexed from,
        address indexed to,
        uint256 id,
        uint256 value
    );

    PermissionedRegistry registry;
    MockHCAFactoryBasic hcaFactory;
    IRegistryMetadata metadata;

    // Role bitmaps for different permission configurations

    uint256 constant DEFAULT_ROLE_BITMAP =
        RegistryRolesLib.ROLE_SET_SUBREGISTRY | RegistryRolesLib.ROLE_SET_RESOLVER;
    uint256 constant LOCKED_RESOLVER_ROLE_BITMAP = RegistryRolesLib.ROLE_SET_SUBREGISTRY;
    uint256 constant LOCKED_SUBREGISTRY_ROLE_BITMAP = RegistryRolesLib.ROLE_SET_RESOLVER;
    uint256 constant NO_ROLES_ROLE_BITMAP = 0;

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");
    address user3 = makeAddr("user3");
    address registrar = makeAddr("registrar");

    string testLabel = "test";
    address testResolver = makeAddr("resolver");
    IRegistry testRegistry = IRegistry(makeAddr("registry"));

    uint256 deployerRoles = EACBaseRolesLib.ALL_ROLES;

    function setUp() public {
        hcaFactory = new MockHCAFactoryBasic();
        metadata = new SimpleRegistryMetadata(hcaFactory);
        registry = new PermissionedRegistry(hcaFactory, metadata, address(this), deployerRoles);
    }

    function test_constructor_sets_roles() public view {
        assertTrue(registry.hasRootRoles(deployerRoles, address(this)));
    }

    function test_Revert_register_without_registrar_role() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_REGISTRAR,
                user1
            )
        );
        vm.prank(user1);
        registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
    }

    function test_Revert_renew_without_renew_role() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        address nonRenewer = makeAddr("nonRenewer");

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_RENEW,
                nonRenewer
            )
        );
        vm.prank(nonRenewer);
        registry.renew(tokenId, _after(172800));
    }

    function test_token_specific_renewer_can_renew() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        address tokenRenewer = makeAddr("tokenRenewer");

        // Grant the RENEW role specifically for this token
        registry.grantRoles(
            registry.getResource(tokenId),
            RegistryRolesLib.ROLE_RENEW,
            tokenRenewer
        );

        // Verify the role was granted
        assertTrue(
            registry.hasRoles(
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_RENEW,
                tokenRenewer
            )
        );

        // This user doesn't have the ROOT_RESOURCE RegistryRolesLib.ROLE_RENEW
        assertFalse(
            registry.hasRoles(registry.ROOT_RESOURCE(), RegistryRolesLib.ROLE_RENEW, tokenRenewer)
        );

        // But should still be able to renew this specific token
        vm.prank(tokenRenewer);
        uint64 newExpiry = _after(172800);
        registry.renew(tokenId, newExpiry);

        uint64 expiry = registry.getExpiry(tokenId);
        assertEq(expiry, newExpiry);
    }

    function test_token_owner_can_renew_if_granted_role() public {
        // Register a token with specific roles including RegistryRolesLib.ROLE_RENEW
        uint256 roleBitmap = DEFAULT_ROLE_BITMAP | RegistryRolesLib.ROLE_RENEW;
        uint256 tokenId = registry.register(
            "test2",
            user1,
            registry,
            address(0),
            roleBitmap,
            _after(86400)
        );

        // Verify the owner has the RENEW role for this token
        assertTrue(
            registry.hasRoles(registry.getResource(tokenId), RegistryRolesLib.ROLE_RENEW, user1)
        );

        // Owner should be able to renew their own token
        vm.prank(user1);
        uint64 newExpiry = _after(172800);
        registry.renew(tokenId, newExpiry);

        uint64 expiry = registry.getExpiry(tokenId);
        assertEq(expiry, newExpiry);
    }

    function test_Revert_owner_cannot_renew_without_role() public {
        // First create a user without global renew permissions
        address tokenOwner = makeAddr("tokenOwner");

        // Register a token with NO roles granted to the owner
        uint256 tokenId = registry.register(
            "test2",
            tokenOwner,
            registry,
            address(0),
            NO_ROLES_ROLE_BITMAP,
            _after(86400)
        );

        // Verify the owner doesn't have the RENEW role for this token (this is the intent of the test)
        assertFalse(
            registry.hasRoles(
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_RENEW,
                tokenOwner
            )
        );

        // Owner should not be able to renew without the role
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_RENEW,
                tokenOwner
            )
        );
        vm.prank(tokenOwner);
        registry.renew(tokenId, _after(172800));
    }

    function test_registrar_can_register() public {
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, registrar);
        vm.prank(registrar);
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
        assertEq(registry.ownerOf(tokenId), address(this));
    }

    function test_renewer_can_renew() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        address renewer = makeAddr("renewer");
        registry.grantRootRoles(RegistryRolesLib.ROLE_RENEW, renewer);

        vm.prank(renewer);
        uint64 newExpiry = _after(172800);
        registry.renew(tokenId, newExpiry);

        uint64 expiry = registry.getExpiry(tokenId);
        assertEq(expiry, newExpiry);
    }

    function test_unregister() external {
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
        vm.expectEmit();
        emit IRegistry.NameUnregistered(tokenId, address(this));
        vm.expectEmit();
        emit IERC1155.TransferSingle(address(this), user1, address(0), tokenId, 1);
        registry.unregister(tokenId);

        // check unregistered state
        assertEq(registry.ownerOf(tokenId), address(0), "owner");
        assertEq(registry.getExpiry(tokenId), block.timestamp, "expiry");
        assertEq(registry.getResolver(testLabel), address(0), "resolver");
        assertEq(address(registry.getSubregistry(testLabel)), address(0), "subregistry");
    }

    function test_unregister_self() external {
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            RegistryRolesLib.ROLE_UNREGISTER, // self unregister
            _after(86400)
        );
        vm.prank(user1);
        registry.unregister(tokenId);
    }

    function test_unregister_available() external {
        uint256 tokenId = 1 << 32;
        vm.expectRevert(abi.encodeWithSelector(IStandardRegistry.NameExpired.selector, tokenId));
        registry.unregister(tokenId);
    }

    function test_unregister_reserved() external {
        uint256 tokenId = registry.reserve(testLabel, testResolver, _after(86400));

        // cant unregister RESERVED with ROLE_UNREGISTER
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                tokenId,
                RegistryRolesLib.ROLE_UNREGISTER,
                registrar
            )
        );
        vm.prank(registrar);
        registry.unregister(tokenId);

        registry.grantRootRoles(RegistryRolesLib.ROLE_UNREGISTER, registrar);
        vm.recordLogs();
        vm.expectEmit();
        emit IRegistry.NameUnregistered(tokenId, registrar);
        vm.prank(registrar);
        registry.unregister(tokenId);
        _expectNoEmit(vm.getRecordedLogs(), IERC1155.TransferSingle.selector);
    }

    function test_reserve() external {
        uint64 expiry = _after(86400);

        assertEq(
            uint256(registry.getNameState(testLabel)),
            uint256(IPermissionedRegistry.NameState.AVAILABLE),
            "state:before-reserve"
        );

        vm.expectEmit();
        emit IRegistry.NameReserved(
            LibLabel.labelToCanonicalId(testLabel),
            LibLabel.labelhash(testLabel),
            testLabel,
            expiry,
            address(this)
        );
        registry.reserve(testLabel, testResolver, expiry);

        // check reservation state
        (uint256 tokenId, ) = registry.getNameData(testLabel);
        assertEq(registry.ownerOf(tokenId), address(0), "owner");
        assertEq(registry.getExpiry(tokenId), expiry, "expiry");
        assertEq(registry.getResolver(testLabel), testResolver, "resolver");
        assertEq(
            uint256(registry.getNameState(testLabel)),
            uint256(IPermissionedRegistry.NameState.RESERVED),
            "state:after-reserve"
        );

        // create restricted registrar
        registry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_RESERVE,
            registrar
        );

        // cant reserve again
        vm.expectRevert(
            abi.encodeWithSelector(IPermissionedRegistry.NameAlreadyReserved.selector, testLabel)
        );
        vm.prank(registrar);
        registry.reserve(testLabel, testResolver, expiry);

        // ROOT can renew
        expiry += expiry;
        registry.renew(tokenId, expiry);

        // ROOT can change resolver
        registry.setResolver(tokenId, testResolver);

        // ROOT can change subregistry
        registry.setSubregistry(tokenId, testRegistry);

        vm.warp(expiry);

        // check expired state
        assertEq(registry.getResolver(testLabel), address(0), "afterResolver");
        assertEq(
            uint256(registry.getNameState(testLabel)),
            uint256(IPermissionedRegistry.NameState.AVAILABLE),
            "state:after-expiry"
        );

        // can be registered after expiry
        vm.prank(registrar);
        registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        assertEq(
            uint256(registry.getNameState(testLabel)),
            uint256(IPermissionedRegistry.NameState.REGISTERED),
            "state:after-register"
        );
    }

    function test_reserve_then_renew() external {
        uint256 tokenId = registry.reserve(testLabel, testResolver, _after(100));
        uint64 newExpiry = _after(200);
        registry.renew(tokenId, newExpiry);
        assertEq(registry.getExpiry(tokenId), newExpiry);
    }

    function test_reserve_then_register() external {
        registry.reserve(testLabel, testResolver, _after(86400));

        // cant register a reservation w/o ROLE_RESERVE
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, registrar);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_RESERVE,
                registrar
            )
        );
        vm.prank(registrar);
        registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // grant and retry
        registry.grantRootRoles(RegistryRolesLib.ROLE_RESERVE, registrar);
        vm.prank(registrar);
        registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
    }

    function test_register_then_reserve() external {
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // cant reserve a registration with ROLE_RESERVE
        registry.grantRootRoles(RegistryRolesLib.ROLE_RESERVE, registrar);
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.NameAlreadyRegistered.selector, testLabel)
        );
        vm.prank(registrar);
        registry.reserve(testLabel, testResolver, _after(86400));

        // cant reserve a registration with ROLE_UNREGISTER
        registry.grantRootRoles(RegistryRolesLib.ROLE_UNREGISTER, registrar);
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.NameAlreadyRegistered.selector, testLabel)
        );
        vm.prank(registrar);
        registry.reserve(testLabel, testResolver, _after(86400));

        // must unregister() then reserve()
        vm.prank(registrar);
        registry.unregister(tokenId);
        vm.prank(registrar);
        registry.reserve(testLabel, testResolver, _after(86400));
    }

    function test_reserve_alreadyRegistered() external {
        registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
        registry.grantRootRoles(RegistryRolesLib.ROLE_RESERVE, registrar);
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.NameAlreadyRegistered.selector, testLabel)
        );
        vm.prank(registrar);
        registry.reserve(testLabel, testResolver, _after(86400));
    }

    function test_reserve_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_RESERVE,
                user1
            )
        );
        vm.prank(user1);
        registry.reserve(testLabel, testResolver, _after(86400));
    }

    function test_register() external {
        uint64 expiry = _after(86400);
        uint256 expectedTokenId = LibLabel.labelToCanonicalId(testLabel);
        vm.expectEmit();
        emit IRegistry.NameRegistered(
            expectedTokenId,
            LibLabel.labelhash(testLabel),
            testLabel,
            user1,
            expiry,
            address(this)
        );
        vm.expectEmit();
        emit IERC1155.TransferSingle(address(this), address(0), user1, expectedTokenId, 1);
        vm.expectEmit();
        emit IPermissionedRegistry.TokenResource(expectedTokenId, expectedTokenId);
        vm.expectEmit();
        emit IRegistry.SubregistryUpdated(expectedTokenId, testRegistry, address(this));
        vm.expectEmit();
        emit IRegistry.ResolverUpdated(expectedTokenId, testResolver, address(this));
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            expiry
        );
        assertEq(registry.getExpiry(tokenId), expiry, "expiry");
        assertEq(registry.ownerOf(tokenId), user1, "owner");
        assertEq(registry.getResolver(testLabel), testResolver, "resolver");
        assertEq(address(registry.getSubregistry(testLabel)), address(testRegistry), "registry");
        assertTrue(registry.hasRoles(tokenId, DEFAULT_ROLE_BITMAP, user1), "roles");
    }

    function test_register_with_roles(uint16 compactRoles) external {
        uint256 rolesBitmap;
        for (uint256 i; i < 16; i++) {
            if ((compactRoles & (1 << i)) != 0) {
                rolesBitmap |= (1 << (i << 2));
            }
        }
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            rolesBitmap,
            _after(86400)
        );
        assertTrue(registry.hasRoles(tokenId, rolesBitmap, user1));
    }

    function test_register_withNullResolver() external {
        vm.recordLogs();
        registry.register(
            testLabel,
            user1,
            testRegistry,
            address(0), // null
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
        _expectNoEmit(vm.getRecordedLogs(), IRegistry.ResolverUpdated.selector);
    }

    function test_register_withNullRegistry() external {
        vm.recordLogs();
        registry.register(
            testLabel,
            user1,
            IRegistry(address(0)), // null
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
        _expectNoEmit(vm.getRecordedLogs(), IRegistry.SubregistryUpdated.selector);
    }

    function test_Revert_register_tooShort() external {
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsEmpty.selector));
        registry.register("", user1, registry, address(0), DEFAULT_ROLE_BITMAP, _after(86400));
    }

    function test_Revert_register_tooLong() external {
        string memory label = new string(256);
        vm.expectRevert(abi.encodeWithSelector(NameCoder.LabelIsTooLong.selector, label));
        registry.register(label, user1, registry, address(0), DEFAULT_ROLE_BITMAP, _after(86400));
    }

    function test_register_then_register() external {
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // cant register again with ROLE_REGISTER
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, registrar);
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.NameAlreadyRegistered.selector, testLabel)
        );
        vm.prank(registrar);
        registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // cant register again with ROLE_UNREGISTER
        registry.grantRootRoles(RegistryRolesLib.ROLE_UNREGISTER, registrar);
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.NameAlreadyRegistered.selector, testLabel)
        );
        vm.prank(registrar);
        registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // must unregister() then register()
        vm.prank(registrar);
        registry.unregister(tokenId);
        vm.prank(registrar);
        registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
    }

    function test_set_subregistry() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
        registry.setSubregistry(tokenId, IRegistry(address(this)));
        vm.assertEq(address(registry.getSubregistry("test2")), address(this));
    }

    function test_Revert_cannot_set_subregistry_without_role() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            LOCKED_SUBREGISTRY_ROLE_BITMAP,
            _after(86400)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_SET_SUBREGISTRY,
                user1
            )
        );
        vm.prank(user1);
        registry.setSubregistry(tokenId, IRegistry(user1));
    }

    function test_set_resolver() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
        registry.setResolver(tokenId, address(this));
        vm.assertEq(address(registry.getResolver("test2")), address(this));
    }

    function test_Revert_cannot_set_resolver_without_role() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            LOCKED_RESOLVER_ROLE_BITMAP,
            _after(86400)
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_SET_RESOLVER,
                user1
            )
        );
        vm.prank(user1);
        registry.setResolver(tokenId, address(this));
    }

    function test_renew_extends_expiry() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );
        uint64 newExpiry = _after(200);
        registry.renew(tokenId, newExpiry);

        uint64 expiry = registry.getExpiry(tokenId);
        assertEq(expiry, newExpiry);
    }

    function test_renew_emits_event() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );
        uint64 newExpiry = _after(200);

        vm.expectEmit();
        emit IRegistry.ExpiryUpdated(tokenId, newExpiry, address(this));
        registry.renew(tokenId, newExpiry);
    }

    function test_Revert_renew_expired_name() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );
        vm.warp(_after(101));

        vm.expectRevert(abi.encodeWithSelector(IStandardRegistry.NameExpired.selector, tokenId));
        registry.renew(tokenId, _after(200));
    }

    function test_Revert_renew_reduce_expiry() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(200)
        );
        uint64 newExpiry = _after(100);

        vm.expectRevert(
            abi.encodeWithSelector(
                IStandardRegistry.CannotReduceExpiration.selector,
                _after(200),
                newExpiry
            )
        );
        registry.renew(tokenId, newExpiry);
    }

    function test_expired_name_has_no_owner() public {
        uint64 expiry = _after(100);
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            expiry
        );
        vm.warp(expiry + 1);
        assertEq(registry.ownerOf(tokenId), address(0), "owner");
        assertEq(registry.latestOwnerOf(tokenId), user1, "latest");
        assertEq(registry.getResolver(testLabel), address(0), "resolver");
        assertEq(address(registry.getSubregistry(testLabel)), address(0), "registry");
    }

    function test_expired_name_can_be_reregistered() public {
        uint64 expiry = _after(100);
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            expiry
        );
        assertEq(registry.ownerOf(tokenId), user1, "owner0");
        vm.warp(expiry + 1);
        assertEq(registry.ownerOf(tokenId), address(0), "owner1");
        uint256 newTokenId = registry.register(
            testLabel,
            user2,
            testRegistry,
            testResolver,
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );
        assertEq(registry.ownerOf(newTokenId), user2, "owner2");

        // The new token ID should be different from the old one
        assertNotEq(tokenId, newTokenId, "regeneration");

        // Both should have the same canonical ID but different token version
        assertEq(registry.getResource(tokenId), registry.getResource(newTokenId), "resource");

        assertEq(
            _tokenVersionId(newTokenId),
            _tokenVersionId(tokenId) + 1,
            "Token version should increment"
        );
    }

    function test_expired_name_returns_zero_subregistry() public {
        registry.register(
            testLabel,
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );
        vm.warp(_after(101));
        assertEq(address(registry.getSubregistry("test2")), address(0));
    }

    function test_expired_name_returns_zero_resolver() public {
        uint256 tokenId = registry.register(
            "test2",
            address(this),
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );
        registry.setResolver(tokenId, address(1));
        vm.warp(_after(101));
        assertEq(registry.getResolver("test2"), address(0));
    }

    function test_expired_name_reregistration_resets_roles() public {
        // Register a name with owner1
        address owner1 = makeAddr("owner1");
        uint256 tokenId = registry.register(
            "resettest",
            owner1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Grant an additional role to owner1
        registry.grantRoles(registry.getResource(tokenId), RegistryRolesLib.ROLE_RENEW, owner1);

        // Verify owner1 has roles
        assertTrue(
            registry.hasRoles(
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_SET_SUBREGISTRY,
                owner1
            )
        );
        assertTrue(
            registry.hasRoles(
                registry.getResource(tokenId),
                RegistryRolesLib.ROLE_SET_RESOLVER,
                owner1
            )
        );
        assertTrue(
            registry.hasRoles(registry.getResource(tokenId), RegistryRolesLib.ROLE_RENEW, owner1)
        );

        uint256 originalResourceId = registry.getResource(tokenId);
        uint32 originalEacVersionId = registry.getEntry(tokenId).eacVersionId;

        // Move time forward to expire the name
        vm.warp(_after(101));

        // Verify token is expired
        assertEq(registry.ownerOf(tokenId), address(0));

        // Re-register with owner2
        address owner2 = makeAddr("owner2");
        uint256 newTokenId = registry.register(
            "resettest",
            owner2,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Verify it's a different token ID
        assertNotEq(newTokenId, tokenId, "Token ID should change after re-registration");

        // Verify eacVersionId has incremented
        uint32 newEacVersionId = registry.getEntry(newTokenId).eacVersionId;
        assertEq(
            newEacVersionId,
            originalEacVersionId + 1,
            "eacVersionId should increment on re-registration"
        );

        // Verify resource ID has changed due to eacVersionId increment
        uint256 newResourceId = registry.getResource(newTokenId);
        assertNotEq(
            newResourceId,
            originalResourceId,
            "Resource ID should change after re-registration due to eacVersionId increment"
        );

        // owner1 should no longer have roles for this token
        // Test specifically using new resource ID
        assertFalse(
            registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, owner1)
        );
        assertFalse(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_RESOLVER, owner1));
        assertFalse(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_RENEW, owner1));

        // And owner2 should have the default roles
        assertTrue(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, owner2));
        assertTrue(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_RESOLVER, owner2));
    }

    function test_eacVersionId_increments_on_reregistration_after_expiry() public {
        string memory label = "eactest";
        address owner1 = makeAddr("owner1");

        // Register a name initially
        uint256 tokenId = registry.register(
            label,
            owner1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Get initial eacVersionId
        uint32 initialEacVersionId = registry.getEntry(tokenId).eacVersionId;
        uint256 initialResourceId = registry.getResource(tokenId);

        // Let the name expire
        vm.warp(_after(101));
        assertEq(registry.ownerOf(tokenId), address(0), "Token should be expired");

        // Re-register the same name with a different owner
        address owner2 = makeAddr("owner2");
        uint256 newTokenId = registry.register(
            label,
            owner2,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Verify eacVersionId has incremented
        uint32 newEacVersionId = registry.getEntry(newTokenId).eacVersionId;
        assertEq(
            newEacVersionId,
            initialEacVersionId + 1,
            "eacVersionId should increment on re-registration"
        );

        // Verify resource ID reflects the new eacVersionId
        uint256 newResourceId = registry.getResource(newTokenId);
        assertNotEq(
            newResourceId,
            initialResourceId,
            "Resource ID should change due to eacVersionId increment"
        );

        // Verify the lower 32 bits of resource ID contain the new eacVersionId
        assertEq(
            uint32(newResourceId),
            newEacVersionId,
            "Resource ID should contain the new eacVersionId in lower 32 bits"
        );
    }

    function test_register_send_to_null_expire_reregister_fresh_acl() public {
        // Register a name initially with transfer admin role
        uint256 roleBitmapWithTransfer = DEFAULT_ROLE_BITMAP |
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = registry.register(
            "nulltest",
            user1,
            registry,
            address(0),
            roleBitmapWithTransfer,
            _after(100)
        );

        // Grant additional roles
        uint256 resourceId = registry.getResource(tokenId);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user1);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, user2);

        // Get current tokenId and eacVersionId after role grants
        uint256 currentTokenId = registry.getTokenId(resourceId);
        uint32 initialEacVersionId = registry.getEntry(currentTokenId).eacVersionId;

        // Verify roles are set
        assertTrue(registry.hasRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user1));
        assertTrue(registry.hasRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, user2));

        // Transfer to temp address and let expire
        address tempOwner = makeAddr("temp");
        vm.prank(user1);
        registry.safeTransferFrom(user1, tempOwner, currentTokenId, 1, "");

        vm.warp(_after(101));
        assertEq(registry.ownerOf(currentTokenId), address(0));

        // Re-register with new owner
        uint256 newTokenId = registry.register(
            "nulltest",
            user3,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Verify fresh ACL
        uint32 newEacVersionId = registry.getEntry(newTokenId).eacVersionId;
        assertEq(newEacVersionId, initialEacVersionId + 1);

        uint256 newResourceId = registry.getResource(newTokenId);
        assertNotEq(newResourceId, resourceId);

        // Old users should have no roles
        assertFalse(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_RENEW, user1));
        assertFalse(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_RESOLVER, user2));

        // New owner should have default roles
        assertTrue(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, user3));
        assertTrue(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_RESOLVER, user3));
    }

    function test_first_time_registration_no_eacVersionId_increment() public {
        string memory label = "firsttime";
        address owner = makeAddr("owner");

        // Verify name has never been registered (entry.expiry should be 0)
        (, IPermissionedRegistry.Entry memory entry) = registry.getNameData(label);
        assertEq(entry.expiry, 0, "Name should never have been registered before");
        assertEq(entry.eacVersionId, 0, "Initial eacVersionId should be 0");

        // Register the name for the first time
        uint256 newTokenId = registry.register(
            label,
            owner,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Verify eacVersionId has NOT incremented (should still be 0)
        uint32 finalEacVersionId = registry.getEntry(newTokenId).eacVersionId;
        assertEq(finalEacVersionId, 0, "eacVersionId should remain 0 for first-time registration");

        // Verify the name is properly registered
        assertEq(registry.ownerOf(newTokenId), owner, "Owner should be set correctly");

        // Verify resource ID contains eacVersionId of 0
        uint256 resourceId = registry.getResource(newTokenId);
        assertEq(
            uint32(resourceId),
            0,
            "Resource ID should contain eacVersionId of 0 for first registration"
        );
    }

    function test_reregistration_with_existing_owner_increments_eacVersionId() public {
        string memory label = "existingowner";
        address owner1 = makeAddr("owner1");

        // Register a name initially
        uint256 tokenId = registry.register(
            label,
            owner1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Get initial state
        uint32 initialEacVersionId = registry.getEntry(tokenId).eacVersionId;
        uint256 initialResourceId = registry.getResource(tokenId);

        // Verify owner1 has the token
        assertEq(registry.ownerOf(tokenId), owner1, "owner1 should own the token");
        assertEq(registry.latestOwnerOf(tokenId), owner1, "owner1 should be latest owner");

        // Let the name expire but don't transfer/burn the token
        // This simulates the edge case where latestOwnerOf still returns an address
        vm.warp(_after(101));

        // Verify token is expired but latestOwnerOf still returns owner1
        assertEq(
            registry.ownerOf(tokenId),
            address(0),
            "Token should be expired (ownerOf returns 0)"
        );
        assertEq(registry.latestOwnerOf(tokenId), owner1, "Latest owner should still be owner1");

        // Re-register the name with a new owner
        address owner2 = makeAddr("owner2");
        uint256 newTokenId = registry.register(
            label,
            owner2,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Verify the old token was burned and eacVersionId incremented
        uint32 newEacVersionId = registry.getEntry(newTokenId).eacVersionId;
        assertEq(
            newEacVersionId,
            initialEacVersionId + 1,
            "eacVersionId should increment even when previous owner existed"
        );

        // Verify resource ID changed
        uint256 newResourceId = registry.getResource(newTokenId);
        assertNotEq(
            newResourceId,
            initialResourceId,
            "Resource ID should change due to eacVersionId increment"
        );

        // Verify new owner has the token
        assertEq(registry.ownerOf(newTokenId), owner2, "owner2 should own the new token");
        assertEq(
            registry.latestOwnerOf(newTokenId),
            owner2,
            "owner2 should be latest owner of new token"
        );

        // Verify token IDs are different
        assertNotEq(newTokenId, tokenId, "New token ID should be different from old token ID");

        // Verify old token is completely gone (should revert or return 0)
        assertEq(registry.ownerOf(tokenId), address(0), "Old token should have no owner");
    }

    function test_token_transfer_also_transfers_roles() public {
        // Register a name with owner1, including ROLE_CAN_TRANSFER_ADMIN
        address owner1 = makeAddr("owner1");
        uint256 roleBitmapWithTransfer = DEFAULT_ROLE_BITMAP |
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = registry.register(
            "transfertest",
            owner1,
            registry,
            address(0),
            roleBitmapWithTransfer,
            _after(100)
        );

        // Capture the resource ID before transfer
        uint256 originalResourceId = registry.getResource(tokenId);

        // Grant additional role to owner1
        registry.grantRoles(originalResourceId, RegistryRolesLib.ROLE_RENEW, owner1);

        // get the new token id
        uint256 newTokenId = registry.getTokenId(originalResourceId);

        // Verify owner1 has roles
        assertTrue(
            registry.hasRoles(
                registry.getResource(newTokenId),
                RegistryRolesLib.ROLE_SET_SUBREGISTRY,
                owner1
            )
        );
        assertTrue(
            registry.hasRoles(
                registry.getResource(newTokenId),
                RegistryRolesLib.ROLE_SET_RESOLVER,
                owner1
            )
        );
        assertTrue(
            registry.hasRoles(registry.getResource(newTokenId), RegistryRolesLib.ROLE_RENEW, owner1)
        );

        // Transfer to owner2
        address owner2 = makeAddr("owner2");
        vm.prank(owner1);
        registry.safeTransferFrom(owner1, owner2, newTokenId, 1, "");

        // Verify token ownership transferred
        assertEq(registry.ownerOf(newTokenId), owner2);

        // Verify the resource ID remains unchanged
        uint256 newResourceId = registry.getResource(newTokenId);
        assertEq(newResourceId, originalResourceId, "Resource ID should be the same");

        // Check using the new resource ID that owner1 no longer has roles
        assertFalse(
            registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, owner1)
        );
        assertFalse(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_RESOLVER, owner1));
        assertFalse(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_RENEW, owner1));

        // New owner should automatically receive any roles after transfer
        assertTrue(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, owner2));
        assertTrue(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_SET_RESOLVER, owner2));
        assertTrue(registry.hasRoles(newResourceId, RegistryRolesLib.ROLE_RENEW, owner2));
    }

    function test_setSubregistry() external {
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            RegistryRolesLib.ROLE_SET_SUBREGISTRY,
            _after(100)
        );
        address newRegistry = makeAddr("new");
        vm.expectEmit();
        emit IRegistry.SubregistryUpdated(tokenId, IRegistry(newRegistry), user1);
        vm.prank(user1);
        registry.setSubregistry(tokenId, IRegistry(newRegistry));
        assertEq(address(registry.getSubregistry(testLabel)), newRegistry);
    }

    function test_setSubregistry_expired() external {
        uint64 expiry = _after(100);
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            EACBaseRolesLib.ALL_ROLES,
            expiry
        );
        vm.warp(expiry + 1);
        vm.expectRevert(abi.encodeWithSelector(IStandardRegistry.NameExpired.selector, tokenId));
        vm.prank(user1);
        registry.setSubregistry(tokenId, testRegistry);
    }

    function test_setResolver() external {
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            RegistryRolesLib.ROLE_SET_RESOLVER,
            _after(100)
        );
        address newResolver = makeAddr("new");
        vm.expectEmit();
        emit IRegistry.ResolverUpdated(tokenId, newResolver, user1);
        vm.prank(user1);
        registry.setResolver(tokenId, newResolver);
        assertEq(registry.getResolver(testLabel), newResolver);
    }

    function test_setResolver_expired() external {
        uint64 expiry = _after(100);
        uint256 tokenId = registry.register(
            testLabel,
            user1,
            testRegistry,
            testResolver,
            EACBaseRolesLib.ALL_ROLES,
            expiry
        );
        vm.warp(expiry + 1);
        vm.expectRevert(abi.encodeWithSelector(IStandardRegistry.NameExpired.selector, tokenId));
        vm.prank(user1);
        registry.setResolver(tokenId, testResolver);
    }

    function test_token_regeneration_on_role_grant() public {
        uint256 tokenId = registry.register(
            "regenerate1",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Record the resource ID (should remain stable)
        uint256 resource = registry.getResource(tokenId);

        vm.expectEmit();
        emit IRegistry.TokenRegenerated(tokenId, tokenId + 1);
        registry.grantRoles(resource, RegistryRolesLib.ROLE_RENEW, user2);
        uint256 tokenId2 = registry.getTokenId(tokenId);

        // Check that the new token ID has the same resource ID
        assertEq(registry.getResource(tokenId2), resource, "Resource ID should remain the same");

        // Verify the owner still owns the token (new token ID)
        assertEq(registry.ownerOf(tokenId2), user1);

        // Verify the owner still has the same permissions
        assertTrue(registry.hasRoles(tokenId2, DEFAULT_ROLE_BITMAP, user1));

        // Verify the granted role exists on the resource
        assertTrue(registry.hasRoles(tokenId2, RegistryRolesLib.ROLE_RENEW, user2));
    }

    function test_token_regeneration_on_role_revoke() public {
        // Register a token with owner1
        uint256 tokenId = registry.register(
            "regenerate2",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Record the resource ID (should remain stable)
        uint256 resource = registry.getResource(tokenId);

        // Grant a role to another user first
        registry.grantRoles(tokenId, RegistryRolesLib.ROLE_RENEW, user2);

        // Get the new token ID after first regeneration
        uint256 tokenId2 = registry.getTokenId(tokenId);
        assertEq(tokenId + 1, tokenId2, "token12");
        assertTrue(registry.hasRoles(tokenId2, RegistryRolesLib.ROLE_RENEW, user2), "grant");

        // revoke the role and check regeneration again
        vm.expectEmit();
        emit IRegistry.TokenRegenerated(tokenId2, tokenId2 + 1);
        registry.revokeRoles(tokenId, RegistryRolesLib.ROLE_RENEW, user2);

        uint256 tokenId3 = registry.getTokenId(tokenId);

        assertEq(tokenId2 + 1, tokenId3, "token23");

        // Check that the new token ID has the same resource ID
        assertEq(registry.getResource(tokenId3), resource, "resource");

        // Verify the owner still owns the token (new token ID)
        assertEq(registry.ownerOf(tokenId3), user1, "owner");

        // Verify the owner still has the same permissions
        assertTrue(registry.hasRoles(tokenId3, DEFAULT_ROLE_BITMAP, user1), "same");

        // Verify the revoked role is gone
        assertFalse(registry.hasRoles(tokenId3, RegistryRolesLib.ROLE_RENEW, user2), "revoke");
    }

    function test_maintaining_owner_roles_across_regenerations() public {
        // Register a token with owner1
        address owner1 = makeAddr("owner1");
        uint256 tokenId = registry.register(
            "regenerate3",
            owner1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        // Record the resource ID (should remain stable)
        uint256 resourceId = registry.getResource(tokenId);

        // Grant an additional role to the owner
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, owner1);

        // Get the new token ID after regeneration
        uint256 intermediateTokenId = registry.getTokenId(resourceId);

        // grant a role to another user, triggering another regeneration
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user2);

        // Get the final token ID
        uint256 finalTokenId = registry.getTokenId(resourceId);

        // Verify the token has been regenerated twice
        assertNotEq(tokenId, intermediateTokenId, "Token should be regenerated first time");
        assertNotEq(intermediateTokenId, finalTokenId, "Token should be regenerated second time");

        // Verify the owner still owns the token (new token ID)
        assertEq(registry.ownerOf(finalTokenId), owner1, "still owns the token");

        // Verify the owner still has ALL the permissions
        assertTrue(registry.hasRoles(resourceId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, owner1));
        assertTrue(registry.hasRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, owner1));
        assertTrue(registry.hasRoles(resourceId, RegistryRolesLib.ROLE_RENEW, owner1));

        // Verify the other user has their role
        assertTrue(registry.hasRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user2));
    }

    function test_token_regeneration_latestOwnerOf() public {
        uint256 tokenId = registry.register(
            "regenerate4",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );
        uint256 resourceId = registry.getResource(tokenId);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user1);
        uint256 newTokenId = registry.getTokenId(resourceId);
        assertNotEq(tokenId, newTokenId, "token");
        vm.warp(_after(101));
        assertEq(registry.ownerOf(tokenId), address(0), "owner0");
        assertEq(registry.latestOwnerOf(tokenId), address(0), "latest0");
        assertEq(registry.ownerOf(newTokenId), address(0), "owner1");
        assertEq(registry.latestOwnerOf(newTokenId), user1, "latest1");
    }

    // getRoleAssigneeCount tests

    function test_getRoleAssigneeCount_single_role_single_assignee() public {
        uint256 tokenId = registry.register(
            "counttest1",
            user1,
            registry,
            address(0),
            RegistryRolesLib.ROLE_SET_RESOLVER,
            _after(86400)
        );

        (uint256 counts, ) = registry.getAssigneeCount(tokenId, RegistryRolesLib.ROLE_SET_RESOLVER);

        // Count of 1 for ROLE_SET_RESOLVER
        uint256 expectedCount = 1 * RegistryRolesLib.ROLE_SET_RESOLVER;
        assertEq(counts, expectedCount, "Should have count of 1 for SET_RESOLVER role");
    }

    function test_getRoleAssigneeCount_single_role_multiple_assignees() public {
        uint256 tokenId = registry.register(
            "counttest2",
            user1,
            registry,
            address(0),
            RegistryRolesLib.ROLE_SET_RESOLVER,
            _after(86400)
        );

        // Grant the same role to additional users
        uint256 resourceId = registry.getResource(tokenId);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, user2);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, user3);

        // Get the updated token ID after regenerations
        uint256 currentTokenId = registry.getTokenId(resourceId);

        (uint256 counts, ) = registry.getAssigneeCount(
            currentTokenId,
            RegistryRolesLib.ROLE_SET_RESOLVER
        );

        // Should have count of 3 for ROLE_SET_RESOLVER
        uint256 expectedCount = 3 * RegistryRolesLib.ROLE_SET_RESOLVER;
        assertEq(counts, expectedCount, "Should have count of 3 for SET_RESOLVER role");
    }

    function test_getRoleAssigneeCount_single_role_no_assignees() public {
        uint256 tokenId = registry.register(
            "counttest3",
            user1,
            registry,
            address(0),
            RegistryRolesLib.ROLE_SET_RESOLVER,
            _after(86400)
        );

        (uint256 counts, ) = registry.getAssigneeCount(tokenId, RegistryRolesLib.ROLE_RENEW);

        assertEq(counts, 0, "Should have count of 0 for unassigned RENEW role");
    }

    function test_getRoleAssigneeCount_multiple_roles_mixed_assignees() public {
        uint256 tokenId = registry.register(
            "counttest4",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // Grant additional roles to different users
        uint256 resourceId = registry.getResource(tokenId);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, user2);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user2);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user3);

        // Get the updated token ID after regenerations
        uint256 currentTokenId = registry.getTokenId(resourceId);

        // Query for SET_RESOLVER and RENEW roles
        uint256 queryBitmap = RegistryRolesLib.ROLE_SET_RESOLVER | RegistryRolesLib.ROLE_RENEW;
        (uint256 counts, ) = registry.getAssigneeCount(currentTokenId, queryBitmap);

        // user1 has SET_RESOLVER (from DEFAULT_ROLE_BITMAP), user2 has SET_RESOLVER + RENEW, user3 has RENEW
        // SET_RESOLVER: 2 assignees
        // RENEW: 2 assignees
        uint256 expectedCount = (2 * RegistryRolesLib.ROLE_SET_RESOLVER) |
            (2 * RegistryRolesLib.ROLE_RENEW);
        assertEq(counts, expectedCount, "Should have correct counts for both roles");
    }

    function test_getRoleAssigneeCount_multiple_roles_partial_assignees() public {
        uint256 tokenId = registry.register(
            "counttest5",
            user1,
            registry,
            address(0),
            RegistryRolesLib.ROLE_SET_RESOLVER,
            _after(86400)
        );

        // Query for multiple roles where only SET_RESOLVER has assignees
        uint256 queryBitmap = RegistryRolesLib.ROLE_SET_RESOLVER | RegistryRolesLib.ROLE_RENEW;
        (uint256 counts, ) = registry.getAssigneeCount(tokenId, queryBitmap);

        // Only SET_RESOLVER should have 1 assignee
        uint256 expectedCount = 1 * RegistryRolesLib.ROLE_SET_RESOLVER;
        assertEq(counts, expectedCount, "Should have count only for SET_RESOLVER");
    }

    function test_getRoleAssigneeCount_all_default_roles() public {
        uint256 tokenId = registry.register(
            "counttest6",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        (uint256 counts, ) = registry.getAssigneeCount(tokenId, DEFAULT_ROLE_BITMAP);

        // DEFAULT_ROLE_BITMAP includes SET_SUBREGISTRY and SET_RESOLVER
        // Each should have 1 assignee
        uint256 expectedCount = (1 * RegistryRolesLib.ROLE_SET_SUBREGISTRY) |
            (1 * RegistryRolesLib.ROLE_SET_RESOLVER);
        assertEq(counts, expectedCount, "Should have count of 1 for each default role");
    }

    function test_getRoleAssigneeCount_overlapping_role_assignments() public {
        uint256 tokenId = registry.register(
            "counttest7",
            user1,
            registry,
            address(0),
            RegistryRolesLib.ROLE_SET_RESOLVER,
            _after(86400)
        );

        uint256 resourceId = registry.getResource(tokenId);

        // Grant overlapping roles
        registry.grantRoles(
            resourceId,
            RegistryRolesLib.ROLE_SET_RESOLVER | RegistryRolesLib.ROLE_RENEW,
            user2
        );
        registry.grantRoles(
            resourceId,
            RegistryRolesLib.ROLE_RENEW | RegistryRolesLib.ROLE_SET_SUBREGISTRY,
            user3
        );

        // Get the updated token ID after regenerations
        uint256 currentTokenId = registry.getTokenId(resourceId);

        // Query for all three roles
        uint256 queryBitmap = RegistryRolesLib.ROLE_SET_RESOLVER |
            RegistryRolesLib.ROLE_RENEW |
            RegistryRolesLib.ROLE_SET_SUBREGISTRY;
        (uint256 counts, ) = registry.getAssigneeCount(currentTokenId, queryBitmap);

        // user1: SET_RESOLVER
        // user2: SET_RESOLVER, RENEW
        // user3: RENEW, SET_SUBREGISTRY
        // SET_RESOLVER: 2 assignees -> 2 at bit position of ROLE_SET_RESOLVER
        // RENEW: 2 assignees -> 2 at bit position of ROLE_RENEW
        // SET_SUBREGISTRY: 1 assignee -> 1 at bit position of ROLE_SET_SUBREGISTRY
        uint256 expectedCount = (2 * RegistryRolesLib.ROLE_SET_RESOLVER) |
            (2 * RegistryRolesLib.ROLE_RENEW) |
            (1 * RegistryRolesLib.ROLE_SET_SUBREGISTRY);
        assertEq(counts, expectedCount, "Should have correct counts for all roles");
    }

    function test_getRoleAssigneeCount_after_role_revocation() public {
        uint256 tokenId = registry.register(
            "counttest8",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        uint256 resourceId = registry.getResource(tokenId);

        // Grant role to user2
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, user2);
        uint256 tokenIdAfterGrant = registry.getTokenId(resourceId);

        // Check count before revocation - should have 2 assignees for SET_RESOLVER
        (uint256 countsBefore, ) = registry.getAssigneeCount(
            tokenIdAfterGrant,
            RegistryRolesLib.ROLE_SET_RESOLVER
        );
        uint256 expectedCountBefore = 2 * RegistryRolesLib.ROLE_SET_RESOLVER;
        assertEq(countsBefore, expectedCountBefore, "Should have 2 assignees before revocation");

        // Revoke role from user2
        registry.revokeRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, user2);
        uint256 tokenIdAfterRevoke = registry.getTokenId(resourceId);

        // Check count after revocation - should have 1 assignee for SET_RESOLVER
        (uint256 countsAfter, ) = registry.getAssigneeCount(
            tokenIdAfterRevoke,
            RegistryRolesLib.ROLE_SET_RESOLVER
        );
        uint256 expectedCountAfter = 1 * RegistryRolesLib.ROLE_SET_RESOLVER;
        assertEq(countsAfter, expectedCountAfter, "Should have 1 assignee after revocation");
    }

    function test_getRoleAssigneeCount_zero_bitmap() public {
        uint256 tokenId = registry.register(
            "counttest9",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        (uint256 counts, ) = registry.getAssigneeCount(tokenId, 0);

        assertEq(counts, 0, "Should have 0 counts for empty bitmap");
    }

    function test_transfer_succeeds_with_max_assignees_BET_430() public {
        // Register a token with default roles including ROLE_CAN_TRANSFER_ADMIN
        address tokenOwner = makeAddr("tokenOwner");
        uint256 roleBitmapWithTransfer = DEFAULT_ROLE_BITMAP |
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = registry.register(
            "maxtransfertest",
            tokenOwner,
            registry,
            address(0),
            roleBitmapWithTransfer,
            _after(86400)
        );

        uint256 resourceId = registry.getResource(tokenId);

        // Create 14 additional addresses and grant them the same role as the token owner has
        address[] memory additionalUsers = new address[](14);
        for (uint256 i = 0; i < 14; i++) {
            additionalUsers[i] = makeAddr(string(abi.encodePacked("maxUser", i)));
            // Grant ROLE_SET_RESOLVER to reach max assignees (owner + 14 others = 15 total)
            registry.grantRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, additionalUsers[i]);
        }

        // Get the current token ID after role grants (which may have triggered regeneration)
        uint256 currentTokenId = registry.getTokenId(resourceId);

        // Verify we have 15 assignees for ROLE_SET_RESOLVER (max allowed)
        (uint256 counts, ) = registry.getAssigneeCount(
            currentTokenId,
            RegistryRolesLib.ROLE_SET_RESOLVER
        );
        uint256 expectedCount = 15 * RegistryRolesLib.ROLE_SET_RESOLVER;
        assertEq(counts, expectedCount, "Should have 15 assignees for ROLE_SET_RESOLVER");

        // attempt to transfer the token to a new address
        address newOwner = makeAddr("newTokenOwner");

        // This transfer should NOT fail even though we're at max assignees
        vm.prank(tokenOwner);
        registry.safeTransferFrom(tokenOwner, newOwner, currentTokenId, 1, "");

        // Verify the transfer succeeded
        assertEq(
            registry.ownerOf(currentTokenId),
            newOwner,
            "Token should be transferred to new owner"
        );

        // Verify the new owner has the roles
        assertTrue(
            registry.hasRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, newOwner),
            "New owner should have ROLE_SET_RESOLVER"
        );

        // Verify the old owner no longer has roles
        assertFalse(
            registry.hasRoles(resourceId, RegistryRolesLib.ROLE_SET_RESOLVER, tokenOwner),
            "Old owner should no longer have ROLE_SET_RESOLVER"
        );

        // Verify we still have 15 total assignees (the 14 additional users + new owner)
        (uint256 countsAfter, ) = registry.getAssigneeCount(
            currentTokenId,
            RegistryRolesLib.ROLE_SET_RESOLVER
        );
        assertEq(countsAfter, expectedCount, "Should still have 15 assignees after transfer");
    }

    function test_getRoleAssigneeCount_nonexistent_role() public {
        uint256 tokenId = registry.register(
            "counttest10",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // Use a role that wasn't assigned during default registration
        uint256 nonexistentRole = RegistryRolesLib.ROLE_RENEW; // RENEW role which won't be assigned during default registration
        (uint256 counts, ) = registry.getAssigneeCount(tokenId, nonexistentRole);

        assertEq(counts, 0, "Should have 0 counts for nonexistent role");
    }

    // Token ID Generation Tests

    function test_registration_generates_correct_tokenId() public {
        string memory label = "tokentest";
        uint256 tokenId = registry.register(
            label,
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // Verify the token ID has correct structure
        uint256 canonicalId = LibLabel.getCanonicalId(tokenId);
        uint32 tokenVersionId = _tokenVersionId(tokenId);

        // First registration should have version ID of 0
        assertEq(tokenVersionId, 0, "Initial token version ID should be 0");

        // Canonical ID should match label hash with lower 32 bits cleared
        uint256 expectedCanonicalId = LibLabel.labelToCanonicalId(label);
        assertEq(canonicalId, expectedCanonicalId, "Canonical ID should match label hash");
    }

    function test_token_regeneration_increments_tokenVersionId() public {
        string memory label = "regentest";
        uint256 tokenId = registry.register(
            label,
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        uint256 resourceId = registry.getResource(tokenId);
        uint32 initialTokenVersionId = _tokenVersionId(tokenId);

        // Grant a role to trigger regeneration
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user2);

        // Get the new token ID
        uint256 newTokenId = registry.getTokenId(resourceId);
        uint32 newTokenVersionId = _tokenVersionId(newTokenId);

        // Token version should increment
        assertEq(newTokenVersionId, initialTokenVersionId + 1, "Token version ID should increment");

        // Resource ID should remain the same (EAC version is stable within the resource)
        uint256 newResourceId = registry.getResource(newTokenId);
        assertEq(newResourceId, resourceId, "Resource ID should remain the same");
    }

    function test_multiple_regenerations_increment_correctly() public {
        string memory label = "multiregentest";
        uint256 tokenId = registry.register(
            label,
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        uint256 resourceId = registry.getResource(tokenId);
        uint32 initialTokenVersionId = _tokenVersionId(tokenId);

        // First regeneration
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user2);
        uint256 tokenId1 = registry.getTokenId(resourceId);
        uint32 tokenVersionId1 = _tokenVersionId(tokenId1);

        // Second regeneration
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, user3);
        uint256 tokenId2 = registry.getTokenId(resourceId);
        uint32 tokenVersionId2 = _tokenVersionId(tokenId2);

        // Third regeneration
        registry.revokeRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user2);
        uint256 tokenId3 = registry.getTokenId(resourceId);
        uint32 tokenVersionId3 = _tokenVersionId(tokenId3);

        // Verify incremental progression
        assertEq(
            tokenVersionId1,
            initialTokenVersionId + 1,
            "First regeneration should increment by 1"
        );
        assertEq(
            tokenVersionId2,
            initialTokenVersionId + 2,
            "Second regeneration should increment by 2"
        );
        assertEq(
            tokenVersionId3,
            initialTokenVersionId + 3,
            "Third regeneration should increment by 3"
        );
    }

    function test_reregistration_after_expiry_resets_tokenVersionId() public {
        string memory label = "expirytest";
        uint256 tokenId = registry.register(
            label,
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        uint256 resourceId = registry.getResource(tokenId);

        // Trigger some regenerations to increment version
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user2);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_SET_SUBREGISTRY, user2);

        uint256 preExpiryTokenId = registry.getTokenId(resourceId);
        uint32 preExpiryTokenVersionId = _tokenVersionId(preExpiryTokenId);

        // Should have incremented
        assertGt(preExpiryTokenVersionId, 0, "Pre-expiry token version should have incremented");

        // Expire the token
        vm.warp(_after(101));

        // Re-register
        address newOwner = makeAddr("newExpiryOwner");
        uint256 newTokenId = registry.register(
            label,
            newOwner,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(100)
        );

        uint32 newTokenVersionId = _tokenVersionId(newTokenId);

        // Token version should increment even after expiry
        assertEq(
            newTokenVersionId,
            preExpiryTokenVersionId + 1,
            "New registration should increment token version ID"
        );

        // But the new token ID should be different from the expired one
        assertNotEq(
            newTokenId,
            preExpiryTokenId,
            "New token ID should be different after re-registration"
        );
    }

    // Integration and Edge Case Tests

    function test_tokenId_consistency_across_operations() public {
        string memory label = "consistencytest";
        uint256 tokenId = registry.register(
            label,
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        uint256 resourceId = registry.getResource(tokenId);

        // Store initial state
        uint32 initialTokenVersionId = _tokenVersionId(tokenId);

        // Perform various operations that should maintain consistency
        registry.setSubregistry(tokenId, IRegistry(address(this)));
        registry.setResolver(tokenId, address(this));
        registry.renew(tokenId, _after(172800));

        // Token ID should remain the same for non-regenerating operations
        assertEq(registry.ownerOf(tokenId), user1, "Owner should remain the same");
        assertEq(
            _tokenVersionId(tokenId),
            initialTokenVersionId,
            "Token version should not change"
        );

        // Resource ID should remain consistent
        uint256 currentResourceId = registry.getResource(tokenId);
        assertEq(currentResourceId, resourceId, "Resource ID should remain consistent");
    }

    function test_tokenId_transfer_maintains_structure() public {
        string memory label = "transferstructure";
        uint256 roleBitmapWithTransfer = DEFAULT_ROLE_BITMAP |
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = registry.register(
            label,
            user1,
            registry,
            address(0),
            roleBitmapWithTransfer,
            _after(86400)
        );

        // Trigger regeneration to get non-zero version
        uint256 resourceId = registry.getResource(tokenId);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user2);

        uint256 regeneratedTokenId = registry.getTokenId(resourceId);
        uint32 preTransferTokenVersionId = _tokenVersionId(regeneratedTokenId);

        // Transfer the token
        vm.prank(user1);
        registry.safeTransferFrom(user1, user3, regeneratedTokenId, 1, "");

        // Verify token ID structure is preserved after transfer
        assertEq(registry.ownerOf(regeneratedTokenId), user3, "Token should be transferred");
        assertEq(
            _tokenVersionId(regeneratedTokenId),
            preTransferTokenVersionId,
            "Token version should be preserved"
        );

        // Resource ID should remain the same
        uint256 postTransferResourceId = registry.getResource(regeneratedTokenId);
        assertEq(
            postTransferResourceId,
            resourceId,
            "Resource ID should remain the same after transfer"
        );
    }

    function test_tokenId_uniqueness_across_labels() public {
        // Register multiple tokens and ensure they have unique IDs
        string[] memory labels = new string[](5);
        labels[0] = "unique1";
        labels[1] = "unique2";
        labels[2] = "unique3";
        labels[3] = "unique4";
        labels[4] = "unique5";

        uint256[] memory tokenIds = new uint256[](5);
        uint256[] memory canonicalIds = new uint256[](5);

        for (uint256 i = 0; i < labels.length; i++) {
            tokenIds[i] = registry.register(
                labels[i],
                user1,
                registry,
                address(0),
                DEFAULT_ROLE_BITMAP,
                _after(86400)
            );
            canonicalIds[i] = registry.getResource(tokenIds[i]);
        }

        // Verify all token IDs are unique
        for (uint256 i = 0; i < tokenIds.length; i++) {
            for (uint256 j = i + 1; j < tokenIds.length; j++) {
                assertNotEq(tokenIds[i], tokenIds[j], "Token IDs should be unique");
                assertNotEq(canonicalIds[i], canonicalIds[j], "Canonical IDs should be unique");
            }
        }
    }

    function test_resource_token_roundtrip() public {
        string memory label = "roundtriptest";
        uint256 tokenId = registry.register(
            label,
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        uint256 resourceId = registry.getResource(tokenId);
        uint256 reconstructedTokenId = registry.getTokenId(resourceId);

        // The reconstructed token ID should equal the original
        assertEq(reconstructedTokenId, tokenId, "Round-trip conversion should work");

        // Check that the owner is correctly recognized
        address ownerOfReconstructedTokenId = registry.ownerOf(reconstructedTokenId);
        assertEq(
            ownerOfReconstructedTokenId,
            user1,
            "Owner should be found for reconstructed token ID"
        );
    }

    function test_getNameData_returns_correct_tokenId() public {
        string memory label = "namedatatest";
        uint256 registeredTokenId = registry.register(
            label,
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // Trigger regeneration
        uint256 resourceId = registry.getResource(registeredTokenId);
        registry.grantRoles(resourceId, RegistryRolesLib.ROLE_RENEW, user2);

        // Get current token ID after regeneration
        uint256 currentTokenId = registry.getTokenId(resourceId);

        // Use getNameData to retrieve token ID
        (uint256 retrievedTokenId, IPermissionedRegistry.Entry memory entry) = registry.getNameData(
            label
        );

        // Should match the current (regenerated) token ID
        assertEq(retrievedTokenId, currentTokenId, "getNameData should return current token ID");
        assertNotEq(
            retrievedTokenId,
            registeredTokenId,
            "Should not return original token ID after regeneration"
        );

        // Verify entry data matches
        IPermissionedRegistry.Entry memory currentEntry = registry.getEntry(currentTokenId);
        assertEq(
            entry.tokenVersionId,
            currentEntry.tokenVersionId,
            "Entry token version should match"
        );
        assertEq(entry.eacVersionId, currentEntry.eacVersionId, "Entry EAC version should match");
    }

    // ROLE_CAN_TRANSFER_ADMIN tests
    function test_transfer_with_role_can_transfer_admin() public {
        // Register a name with ROLE_CAN_TRANSFER_ADMIN included
        uint256 roleBitmapWithTransfer = DEFAULT_ROLE_BITMAP |
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = registry.register(
            "transfertest1",
            user1,
            registry,
            address(0),
            roleBitmapWithTransfer,
            _after(86400)
        );

        // Transfer should succeed
        vm.prank(user1);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");

        assertEq(registry.ownerOf(tokenId), user2);
    }

    function test_Revert_transfer_without_role_can_transfer_admin() public {
        // Register a name without ROLE_CAN_TRANSFER_ADMIN
        uint256 tokenId = registry.register(
            "transfertest2",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // Transfer should revert
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.TransferDisallowed.selector, tokenId, user1)
        );
        vm.prank(user1);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");
    }

    function test_transfer_after_revoking_role_can_transfer_admin() public {
        // Register a name with ROLE_CAN_TRANSFER_ADMIN
        uint256 roleBitmapWithTransfer = DEFAULT_ROLE_BITMAP |
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = registry.register(
            "transfertest4",
            user1,
            registry,
            address(0),
            roleBitmapWithTransfer,
            _after(86400)
        );
        uint256 resource = registry.getResource(tokenId);

        // First transfer should succeed
        vm.prank(user1);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");
        assertEq(registry.ownerOf(tokenId), user2);

        // Revoke ROLE_CAN_TRANSFER_ADMIN from user2
        registry.revokeRoles(resource, RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN, user2);
        uint256 newTokenId = registry.getTokenId(resource);

        // Transfer should now fail
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.TransferDisallowed.selector, newTokenId, user2)
        );
        vm.prank(user2);
        registry.safeTransferFrom(user2, user3, newTokenId, 1, "");
    }

    function test_batch_transfer_requires_role_can_transfer_admin() public {
        // Register two names, one with ROLE_CAN_TRANSFER_ADMIN, one without
        uint256 roleBitmapWithTransfer = DEFAULT_ROLE_BITMAP |
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId1 = registry.register(
            "batchtest1",
            user1,
            registry,
            address(0),
            roleBitmapWithTransfer,
            _after(86400)
        );
        uint256 tokenId2 = registry.register(
            "batchtest2",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        uint256[] memory tokenIds = new uint256[](2);
        tokenIds[0] = tokenId1;
        tokenIds[1] = tokenId2;

        uint256[] memory amounts = new uint256[](2);
        amounts[0] = 1;
        amounts[1] = 1;

        // Batch transfer should fail because tokenId2 lacks ROLE_CAN_TRANSFER_ADMIN
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.TransferDisallowed.selector, tokenId2, user1)
        );
        vm.prank(user1);
        registry.safeBatchTransferFrom(user1, user2, tokenIds, amounts, "");
    }

    function test_mint_does_not_require_role_can_transfer_admin() public {
        // This is tested implicitly by register() function calls above
        // Mints (from address(0)) should not require ROLE_CAN_TRANSFER_ADMIN
        uint256 tokenId = registry.register(
            "minttest",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        assertEq(registry.ownerOf(tokenId), user1);
    }

    function test_token_regeneration_works_without_role_can_transfer_admin() public {
        // Register a name without ROLE_CAN_TRANSFER_ADMIN
        uint256 tokenId = registry.register(
            "regentest",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );
        uint256 resource = registry.getResource(tokenId);

        // Grant another role to trigger regeneration
        registry.grantRoles(resource, RegistryRolesLib.ROLE_RENEW, user1);

        // Token should regenerate successfully (internal burn + mint)
        uint256 newTokenId = registry.getTokenId(resource);
        assertNotEq(tokenId, newTokenId);
        assertEq(registry.ownerOf(newTokenId), user1);
    }

    function test_approved_operator_cannot_transfer_without_role_can_transfer_admin() public {
        // Register a name without ROLE_CAN_TRANSFER_ADMIN
        uint256 tokenId = registry.register(
            "approvaltest",
            user1,
            registry,
            address(0),
            DEFAULT_ROLE_BITMAP,
            _after(86400)
        );

        // Approve operator
        vm.prank(user1);
        registry.setApprovalForAll(user2, true);

        // Operator should not be able to transfer without ROLE_CAN_TRANSFER_ADMIN on the owner
        vm.expectRevert(
            abi.encodeWithSelector(IStandardRegistry.TransferDisallowed.selector, tokenId, user1)
        );
        vm.prank(user2);
        registry.safeTransferFrom(user1, user2, tokenId, 1, "");
    }

    function test_grantRoles_rejects_admin_roles_in_registry() public {
        // Register a name with roles including admin roles
        uint256 roleBitmap = RegistryRolesLib.ROLE_SET_RESOLVER |
            RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN |
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = registry.register(
            "admintest",
            user1,
            registry,
            address(0),
            roleBitmap,
            _after(86400)
        );
        uint256 resource = registry.getResource(tokenId);

        // Verify that attempting to grant admin roles reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                resource,
                RegistryRolesLib.ROLE_RENEW_ADMIN,
                address(this)
            )
        );
        registry.grantRoles(resource, RegistryRolesLib.ROLE_RENEW_ADMIN, user2);

        // Test with multiple admin roles
        uint256 multipleAdminRoles = RegistryRolesLib.ROLE_RENEW_ADMIN |
            RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                resource,
                multipleAdminRoles,
                address(this)
            )
        );
        registry.grantRoles(resource, multipleAdminRoles, user2);

        // Test with mixed regular and admin roles
        uint256 mixedRoles = RegistryRolesLib.ROLE_RENEW | RegistryRolesLib.ROLE_RENEW_ADMIN;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                resource,
                mixedRoles,
                address(this)
            )
        );
        registry.grantRoles(resource, mixedRoles, user2);

        // Verify that regular roles can still be granted
        registry.grantRoles(resource, RegistryRolesLib.ROLE_RENEW, user2);
        assertTrue(registry.hasRoles(resource, RegistryRolesLib.ROLE_RENEW, user2));
    }

    function test_grantRootRoles_rejects_admin_roles_in_registry() public {
        // Verify that attempting to grant admin roles in ROOT_RESOURCE reverts
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                registry.ROOT_RESOURCE(),
                RegistryRolesLib.ROLE_REGISTRAR_ADMIN,
                address(this)
            )
        );
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR_ADMIN, user1);

        // Test with multiple admin roles
        uint256 multipleAdminRoles = RegistryRolesLib.ROLE_REGISTRAR_ADMIN |
            RegistryRolesLib.ROLE_RENEW_ADMIN;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                registry.ROOT_RESOURCE(),
                multipleAdminRoles,
                address(this)
            )
        );
        registry.grantRootRoles(multipleAdminRoles, user1);

        // Verify that regular roles can still be granted
        registry.grantRootRoles(RegistryRolesLib.ROLE_REGISTRAR, user1);
        assertTrue(registry.hasRootRoles(RegistryRolesLib.ROLE_REGISTRAR, user1));
    }

    function test_admin_roles_can_be_revoked_in_registry() public {
        // Register a name with admin roles (granted during registration)
        uint256 roleBitmap = RegistryRolesLib.ROLE_SET_RESOLVER |
            RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN |
            RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;
        uint256 tokenId = registry.register(
            "revokeadmintest",
            user1,
            registry,
            address(0),
            roleBitmap,
            _after(86400)
        );
        uint256 resource = registry.getResource(tokenId);

        // Verify user1 has admin roles from registration
        assertTrue(registry.hasRoles(resource, RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN, user1));

        // Verify that admin roles CAN be revoked (this should work)
        registry.revokeRoles(resource, RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN, user1);
        assertFalse(registry.hasRoles(resource, RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN, user1));
    }

    function _tokenVersionId(uint256 id) internal pure returns (uint32) {
        return uint32(id);
    }

    function _after(uint256 dt) internal view returns (uint64) {
        return uint64(block.timestamp + dt);
    }

    function _expectNoEmit(Vm.Log[] memory logs, bytes32 topic0) internal pure {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == topic0) {
                revert(string.concat("found unexpected event: ", vm.toString(topic0)));
            }
        }
    }
}
