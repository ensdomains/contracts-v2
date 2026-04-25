// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test, console} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {
    IRecordResolver,
    IResolverSetters,
    RECORD_RESOLVER_INTERFACE_ID,
    IABIResolver,
    IAddrResolver,
    IAddressResolver,
    IContentHashResolver,
    IDataResolver,
    IHasAddressResolver,
    IInterfaceResolver,
    INameResolver,
    IPubkeyResolver,
    ITextResolver
} from "~src/resolver/interfaces/IRecordResolver.sol";
import {
    PermissionedResolver,
    IPermissionedResolver,
    PermissionedResolverLib,
    IMulticallable,
    NameCoder,
    ENSIP19,
    PERMISSIONED_RESOLVER_INTERFACE_ID,
    COIN_TYPE_ETH,
    COIN_TYPE_DEFAULT
} from "~src/resolver/PermissionedResolver.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

bytes4 constant TEST_SELECTOR = 0x12345678;
bytes constant EMPTY_NAME = hex"00"; // NameCoder.encode("")
string constant TEST_STRING = "abc";

contract PermissionedResolverTest is Test {
    uint256 constant DEFAULT_ROLES = EACBaseRolesLib.ALL_ROLES;

    VerifiableFactory factory;
    MockHCAFactoryBasic hcaFactory;
    PermissionedResolver implementation;
    PermissionedResolver resolver;

    address owner = makeAddr("owner");
    address friend = makeAddr("friend");

    bytes name1;
    bytes32 node1;
    bytes name2;
    bytes32 node2;
    address testAddr = makeAddr("test");
    bytes testAddress = abi.encodePacked(testAddr);

    function setUp() external {
        factory = new VerifiableFactory();
        hcaFactory = new MockHCAFactoryBasic();
        implementation = new PermissionedResolver(hcaFactory);

        name1 = NameCoder.encode("test.eth");
        node1 = NameCoder.namehash(name1, 0);

        name2 = NameCoder.encode("nick.eth");
        node2 = NameCoder.namehash(name2, 0);

        bytes memory initData = abi.encodeCall(
            PermissionedResolver.initialize,
            (owner, DEFAULT_ROLES, new bytes[](0))
        );
        resolver = PermissionedResolver(
            factory.deployProxy(address(implementation), uint256(keccak256(initData)), initData)
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    function test_constructor() external view {
        assertEq(address(resolver.HCA_FACTORY()), address(hcaFactory), "HCA_FACTORY");
    }

    function test_initialize() external view {
        assertTrue(resolver.hasRootRoles(DEFAULT_ROLES, owner), "roles");
    }

    function test_initialize_unowned() external {
        bytes memory initData = abi.encodeCall(
            PermissionedResolver.initialize,
            (address(0), 0, new bytes[](0))
        );
        PermissionedResolver r = PermissionedResolver(
            factory.deployProxy(address(implementation), uint256(keccak256(initData)), initData)
        );
        assertEq(r.roleCount(r.ROOT_RESOURCE()), 0);
    }

    function test_initalize_with_setters() external {
        bytes[] memory m = new bytes[](2);
        m[0] = abi.encodeCall(IResolverSetters.setName, (name1, TEST_STRING));
        m[1] = abi.encodeCall(IResolverSetters.setContentHash, (name2, testAddress));

        bytes memory initData = abi.encodeCall(PermissionedResolver.initialize, (address(0), 0, m));
        PermissionedResolver r = PermissionedResolver(
            factory.deployProxy(address(implementation), uint256(keccak256(initData)), initData)
        );

        assertEq(r.name(node1), TEST_STRING, "name()");
        assertEq(r.contenthash(node2), testAddress, "contenthash()");
    }

    function test_upgrade() external {
        MockUpgrade upgrade = new MockUpgrade();
        vm.prank(owner);
        resolver.upgradeToAndCall(address(upgrade), "");
        assertEq(resolver.getRecordCount(), 12345678);
    }

    function test_upgrade_notAuthorized() external {
        MockUpgrade upgrade = new MockUpgrade();
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                resolver.ROOT_RESOURCE(),
                PermissionedResolverLib.ROLE_UPGRADE,
                friend
            )
        );
        vm.prank(friend);
        resolver.upgradeToAndCall(address(upgrade), "");
    }

    function test_supportsInterface() external view {
        assertTrue(
            resolver.supportsInterface(PERMISSIONED_RESOLVER_INTERFACE_ID),
            "PERMISSIONED_RESOLVER_INTERFACE_ID"
        );
        assertTrue(
            resolver.supportsInterface(RECORD_RESOLVER_INTERFACE_ID),
            "RECORD_RESOLVER_INTERFACE_ID"
        );
        assertTrue(
            resolver.supportsInterface(type(IPermissionedResolver).interfaceId),
            "IPermissionedResolver"
        );
        assertTrue(
            resolver.supportsInterface(type(IRecordResolver).interfaceId),
            "IRecordResolver"
        );
        assertTrue(
            resolver.supportsInterface(type(IResolverSetters).interfaceId),
            "IResolverSetters"
        );
        assertTrue(resolver.supportsInterface(type(IMulticallable).interfaceId), "IMulticallable");
        assertTrue(
            resolver.supportsInterface(type(UUPSUpgradeable).interfaceId),
            "UUPSUpgradeable"
        );

        // profiles
        assertTrue(resolver.supportsInterface(type(IABIResolver).interfaceId), "IABIResolver");
        assertTrue(resolver.supportsInterface(type(IAddrResolver).interfaceId), "IAddrResolver");
        assertTrue(
            resolver.supportsInterface(type(IAddressResolver).interfaceId),
            "IAddressResolver"
        );
        assertTrue(
            resolver.supportsInterface(type(IContentHashResolver).interfaceId),
            "IContentHashResolver"
        );
        assertTrue(resolver.supportsInterface(type(IDataResolver).interfaceId), "IDataResolver");
        assertTrue(
            resolver.supportsInterface(type(IHasAddressResolver).interfaceId),
            "IHasAddressResolver"
        );
        assertTrue(
            resolver.supportsInterface(type(IInterfaceResolver).interfaceId),
            "IInterfaceResolver"
        );
        assertTrue(resolver.supportsInterface(type(INameResolver).interfaceId), "INameResolver");
        assertTrue(
            resolver.supportsInterface(type(IPubkeyResolver).interfaceId),
            "IPubkeyResolver"
        );
        assertTrue(resolver.supportsInterface(type(ITextResolver).interfaceId), "ITextResolver");

        console.log("PERMISSIONED_RESOLVER_INTERFACE_ID:");
        console.logBytes4(PERMISSIONED_RESOLVER_INTERFACE_ID);
        console.log("RECORD_RESOLVER_INTERFACE_ID:");
        console.logBytes4(RECORD_RESOLVER_INTERFACE_ID);
    }

    ////////////////////////////////////////////////////////////////////////
    // EAC grant/revoke disabled
    ////////////////////////////////////////////////////////////////////////

    function test_grantRoles_disabled(uint256 resource, uint8 nibble) external {
        vm.assume(resource > 0 && nibble < 64);
        uint256 roleBitmap = 1 << (nibble << 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                resource,
                roleBitmap,
                friend
            )
        );
        vm.prank(owner);
        resolver.grantRoles(resource, roleBitmap, friend);
    }

    function test_revokeRoles_disabled(uint256 resource, uint8 nibble) external {
        vm.assume(resource > 0 && nibble < 64);
        uint256 roleBitmap = 1 << (nibble << 2);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotRevokeRoles.selector,
                resource,
                roleBitmap,
                friend
            )
        );
        vm.prank(owner);
        resolver.revokeRoles(resource, roleBitmap, friend);
    }

    ////////////////////////////////////////////////////////////////////////
    // authorizeRecordRoles()
    ////////////////////////////////////////////////////////////////////////

    function test_authorizeRecordRoles_anyName() external {
        uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
        uint256 resource = PermissionedResolverLib.resource(0);
        assertEq(resolver.ROOT_RESOURCE(), resource);

        vm.expectEmit();
        emit IEnhancedAccessControl.EACRolesChanged(resource, friend, 0, roleBitmap);
        vm.prank(owner);
        assertTrue(resolver.authorizeRecordRoles(EMPTY_NAME, roleBitmap, friend, true), "grant");
        assertTrue(resolver.hasRoles(resource, roleBitmap, friend), "granted");

        vm.prank(owner);
        assertTrue(resolver.authorizeRecordRoles(EMPTY_NAME, roleBitmap, friend, false), "revoke");
        assertFalse(resolver.hasRoles(resource, roleBitmap, friend), "revoked");
    }

    function test_authorizeRecordRoles_oneName() external {
        uint256 recordId = 1;
        uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
        uint256 resource = PermissionedResolverLib.resource(recordId);

        vm.expectEmit();
        emit IPermissionedResolver.RecordResource(
            recordId,
            resource,
            PermissionedResolverLib.anySetter(name1)
        );
        vm.expectEmit();
        emit IEnhancedAccessControl.EACRolesChanged(resource, friend, 0, roleBitmap);
        vm.prank(owner);
        assertTrue(resolver.authorizeRecordRoles(name1, roleBitmap, friend, true), "grant");
        assertTrue(resolver.hasRoles(resource, roleBitmap, friend), "granted");

        vm.prank(owner);
        assertTrue(resolver.authorizeRecordRoles(name1, roleBitmap, friend, false), "revoke");
        assertFalse(resolver.hasRoles(resource, roleBitmap, friend), "revoked");
    }

    function test_authorizeRecordRoles_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                resolver.ROOT_RESOURCE(),
                PermissionedResolverLib.ROLE_NEW_RECORD,
                friend
            )
        );
        vm.prank(friend);
        resolver.authorizeRecordRoles(name1, EACBaseRolesLib.ALL_ROLES, owner, true);
    }

    function test_authorizeRecordRoles_cannotGrant() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                PermissionedResolverLib.resource(1),
                roleBitmap,
                friend
            )
        );
        vm.prank(friend);
        resolver.authorizeRecordRoles(name1, roleBitmap, owner, true);
    }

    ////////////////////////////////////////////////////////////////////////
    // authorizeSetterRoles()
    ////////////////////////////////////////////////////////////////////////

    function test_authorizeSetterRoles_anyName(string calldata key) external {
        uint256 recordId = 0;
        uint256 resource = PermissionedResolverLib.resource(
            recordId,
            PermissionedResolverLib.partHash(key)
        );
        uint256 roleBitmap = PermissionedResolverLib.ROLE_SET_TEXT;
        bytes memory setter = abi.encodeWithSelector(
            IResolverSetters.setText.selector,
            EMPTY_NAME,
            key
        );

        vm.expectEmit();
        emit IPermissionedResolver.RecordResource(recordId, resource, setter);
        vm.prank(owner);
        assertTrue(resolver.authorizeSetterRoles(setter, friend, true), "grant");
        assertTrue(resolver.hasRoles(resource, roleBitmap, friend), "granted");
        assertFalse(
            resolver.hasRoles(PermissionedResolverLib.resource(recordId), roleBitmap, friend)
        );

        vm.prank(owner);
        assertTrue(resolver.authorizeSetterRoles(setter, friend, false), "revoke");
        assertFalse(resolver.hasRoles(resource, roleBitmap, friend), "revoked");
    }

    function test_authorizeSetterRoles_oneName(string calldata key) external {
        uint256 recordId = 1;
        uint256 resource = PermissionedResolverLib.resource(
            recordId,
            PermissionedResolverLib.partHash(key)
        );
        uint256 roleBitmap = PermissionedResolverLib.ROLE_SET_TEXT;
        bytes memory setter = abi.encodeWithSelector(IResolverSetters.setText.selector, name1, key);

        vm.expectEmit();
        emit IPermissionedResolver.RecordResource(recordId, resource, setter);
        vm.prank(owner);
        assertTrue(resolver.authorizeSetterRoles(setter, friend, true), "grant");
        assertTrue(resolver.hasRoles(resource, roleBitmap, friend), "granted");
        assertFalse(
            resolver.hasRoles(PermissionedResolverLib.resource(recordId), roleBitmap, friend),
            "not granted: other keys"
        );
        assertFalse(
            resolver.hasRoles(PermissionedResolverLib.resource(0), roleBitmap, friend),
            "not granted: other names"
        );

        vm.prank(owner);
        assertTrue(resolver.authorizeSetterRoles(setter, friend, false), "revoke");
        assertFalse(resolver.hasRoles(resource, roleBitmap, friend), "revoked");
    }

    function test_authorizeSetterRoles_cannotGrant() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                resolver.ROOT_RESOURCE(),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.authorizeSetterRoles(
            abi.encodeCall(IResolverSetters.setText, (EMPTY_NAME, "<key>", "<ignored>")),
            owner,
            true
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // update() and link()
    ////////////////////////////////////////////////////////////////////////

    function test_new() external {
        uint256 recordId = 1;
        vm.expectEmit();
        emit IRecordResolver.RecordLinked(node1, name1, recordId, owner);
        vm.expectEmit();
        emit IRecordResolver.NameUpdated(recordId, TEST_STRING, owner);
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING);
    }

    function test_new_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                resolver.ROOT_RESOURCE(),
                PermissionedResolverLib.ROLE_NEW_RECORD,
                address(this)
            )
        );
        resolver.setName(name1, TEST_STRING);
    }

    function test_update() external {
        vm.prank(owner);
        resolver.setName(name1, "before");

        assertEq(resolver.name(node1), "before");

        vm.prank(owner);
        resolver.setName(name1, "after");

        assertEq(resolver.name(node1), "after");
    }

    function test_clear() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        assertEq(resolver.name(node1), TEST_STRING);

        vm.expectEmit();
        emit IRecordResolver.RecordCleared(1, owner);
        vm.prank(owner);
        resolver.clear(name1);

        assertEq(resolver.name(node1), "");
    }

    function test_clear_dne() external {
        vm.prank(owner);
        resolver.clear(name1);

        vm.prank(friend); // noop => callable by anyone
        resolver.clear(name1);

        assertEq(resolver.getRecordId(node1), 0);
    }

    function test_clear_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_CLEAR_RECORD,
                address(this)
            )
        );
        resolver.clear(name1);
    }

    function test_link() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.expectEmit();
        emit IRecordResolver.RecordLinked(node2, name2, 1, owner);
        vm.prank(owner);
        resolver.link(name2, node1);

        assertEq(resolver.name(node2), TEST_STRING);
    }

    function test_link_default() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.prank(owner);
        resolver.link(EMPTY_NAME, node1);
    }

    function test_link_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                resolver.ROOT_RESOURCE(),
                PermissionedResolverLib.ROLE_LINK_RECORD,
                address(this)
            )
        );
        resolver.link(name2, node1);
    }

    function test_link_unknownRecord() external {
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidRecord.selector));
        vm.prank(owner);
        resolver.link(name1, keccak256("dne"));
    }

    function test_unlink() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING);

        vm.expectEmit();
        emit IRecordResolver.RecordLinked(node1, name1, 0, owner);
        vm.prank(owner);
        resolver.link(name1, bytes32(0));

        assertEq(resolver.name(node2), "");
    }

    function test_unlink_default() external {
        vm.prank(owner);
        resolver.setName(EMPTY_NAME, TEST_STRING);

        assertEq(resolver.name(node1), TEST_STRING);

        vm.prank(owner);
        resolver.link(EMPTY_NAME, bytes32(0));

        assertEq(resolver.name(node1), "");
    }

    function test_unlink_alreadyUnlinked() external {
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidRecord.selector));
        vm.prank(owner);
        resolver.link(name1, bytes32(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // getRecordId() and getRecordCount()
    ////////////////////////////////////////////////////////////////////////

    function test_getRecordId() external {
        assertEq(resolver.getRecordId(node1), 0, "unset");

        vm.prank(owner);
        resolver.setName(name1, TEST_STRING);
        assertEq(resolver.getRecordId(node1), 1, "new");

        vm.prank(owner);
        resolver.clear(name1);
        assertEq(resolver.getRecordId(node1), 1, "clear");

        assertEq(resolver.getRecordId(node2), 0, "unset2");

        vm.prank(owner);
        resolver.link(name2, node1);
        assertEq(resolver.getRecordId(node2), 1, "link2");

        vm.prank(owner);
        resolver.link(name2, bytes32(0));

        assertEq(resolver.getRecordId(node2), 0, "unlink2");
    }

    function test_getRecordCount() external {
        assertEq(resolver.getRecordCount(), 0, "empty");

        vm.prank(owner);
        resolver.setName(name1, TEST_STRING);
        assertEq(resolver.getRecordCount(), 1, "new");

        vm.prank(owner);
        resolver.clear(name1);
        assertEq(resolver.getRecordCount(), 1, "edit/clear");

        vm.prank(owner);
        resolver.setName(name2, TEST_STRING);
        assertEq(resolver.getRecordCount(), 2, "new2");

        vm.prank(owner);
        resolver.link(NameCoder.encode("alice.eth"), node1);
        assertEq(resolver.getRecordCount(), 2, "link1");

        vm.prank(owner);
        resolver.link(NameCoder.encode("bob.eth"), node2);
        assertEq(resolver.getRecordCount(), 2, "link2");
    }

    ////////////////////////////////////////////////////////////////////////
    // Standard Resolver Profiles
    ////////////////////////////////////////////////////////////////////////

    function test_setAddress(uint256 coinType) external {
        bytes memory a = vm.randomBytes(20);

        assertFalse(resolver.hasAddr(node1, coinType));

        vm.expectEmit();
        emit IRecordResolver.AddressUpdated(1, coinType, a, owner);
        vm.prank(owner);
        resolver.setAddress(name1, coinType, a);

        assertEq(resolver.addr(node1, coinType), a);
        assertTrue(resolver.hasAddr(node1, coinType));
    }

    function test_setAddress_fallback(uint32 chain) external {
        vm.assume(chain < COIN_TYPE_DEFAULT);
        bytes memory a = vm.randomBytes(20);
        uint256 coinType = chain == 1 ? COIN_TYPE_ETH : (COIN_TYPE_DEFAULT | chain);

        // set default address
        vm.prank(owner);
        resolver.setAddress(name1, COIN_TYPE_DEFAULT, a);

        // get specific address
        assertEq(resolver.addr(node1, coinType), a);
    }

    function test_setAddress_zeroEVM() external {
        assertFalse(resolver.hasAddr(node1, COIN_TYPE_ETH), "unset");

        vm.prank(owner);
        resolver.setAddress(name1, COIN_TYPE_ETH, abi.encodePacked(address(0)));

        assertTrue(resolver.hasAddr(node1, COIN_TYPE_ETH), "set");

        vm.prank(owner);
        resolver.setAddress(name1, COIN_TYPE_ETH, "");

        assertFalse(resolver.hasAddr(node1, COIN_TYPE_ETH), "clear");
    }

    function test_setAddress_zeroEVM_fallbacks() external {
        vm.prank(owner);
        resolver.setAddress(name1, COIN_TYPE_DEFAULT, abi.encodePacked(address(1)));
        vm.prank(owner);
        resolver.setAddress(name1, COIN_TYPE_DEFAULT | 1, abi.encodePacked(address(0)));
        vm.prank(owner);
        resolver.setAddress(name1, COIN_TYPE_DEFAULT | 2, abi.encodePacked(address(2)));

        assertEq(
            resolver.addr(node1, COIN_TYPE_DEFAULT | 1),
            abi.encodePacked(address(0)),
            "block"
        );
        assertEq(
            resolver.addr(node1, COIN_TYPE_DEFAULT | 2),
            abi.encodePacked(address(2)),
            "override"
        );
        assertEq(
            resolver.addr(node1, COIN_TYPE_DEFAULT | 3),
            abi.encodePacked(address(1)),
            "fallback"
        );
    }

    function test_setAddress_invalidEVM_tooShort() external {
        bytes memory v = new bytes(19);
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidEVMAddress.selector, v));
        vm.prank(owner);
        resolver.setAddress(name1, COIN_TYPE_ETH, v);
    }

    function test_setAddress_invalidEVM_tooLong() external {
        bytes memory v = new bytes(21);
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidEVMAddress.selector, v));
        vm.prank(owner);
        resolver.setAddress(name1, COIN_TYPE_ETH, v);
    }

    function test_setAddr_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_ADDRESS,
                address(this)
            )
        );
        resolver.setAddress(name1, COIN_TYPE_ETH, "");
    }

    function test_setText(string calldata key, string calldata value) external {
        vm.expectEmit();
        emit IRecordResolver.TextUpdated(1, key, key, value, owner);
        vm.prank(owner);
        resolver.setText(name1, key, value);

        assertEq(resolver.text(node1, key), value);
    }

    function test_setText_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                address(this)
            )
        );
        resolver.setText(name1, "", "");
    }

    function test_setName(string calldata name) external {
        vm.expectEmit();
        emit IRecordResolver.NameUpdated(1, name, owner);
        vm.prank(owner);
        resolver.setName(name1, name);

        assertEq(resolver.name(node1), name);
    }

    function test_setName_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_NAME,
                address(this)
            )
        );
        resolver.setName(name1, "");
    }

    function test_setContentHash(bytes calldata v) external {
        vm.expectEmit();
        emit IRecordResolver.ContentHashUpdated(1, v, owner);
        vm.prank(owner);
        resolver.setContentHash(name1, v);

        assertEq(resolver.contenthash(node1), v);
    }

    function test_setContentHash_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_CONTENTHASH,
                address(this)
            )
        );
        resolver.setContentHash(name1, "");
    }

    function test_setPubkey(bytes32 x, bytes32 y) external {
        vm.expectEmit();
        emit IRecordResolver.PubkeyUpdated(1, x, y, owner);
        vm.prank(owner);
        resolver.setPubkey(name1, x, y);

        (bytes32 x_, bytes32 y_) = resolver.pubkey(node1);
        assertEq(abi.encode(x_, y_), abi.encode(x, y));
    }

    function test_setPubkey_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_PUBKEY,
                address(this)
            )
        );
        resolver.setPubkey(name1, 0, 0);
    }

    function test_setABI(uint8 bit, bytes calldata data) external {
        uint256 contentType = 1 << bit;

        vm.expectEmit();
        emit IRecordResolver.ABIUpdated(1, contentType, owner);
        vm.prank(owner);
        resolver.setABI(name1, contentType, data);

        uint256 contentTypes = ~uint256(0); // try them all
        (uint256 contentType_, bytes memory data_) = resolver.ABI(node1, contentTypes);
        bytes memory expect = data.length > 0 ? abi.encode(contentType, data) : abi.encode(0, "");
        assertEq(abi.encode(contentType_, data_), expect);
    }

    function test_setABI_invalidContentType_noBits() external {
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidContentType.selector, 0));
        vm.prank(owner);
        resolver.setABI(name1, 0, "");
    }

    function test_setABI_invalidContentType_multipleBits() external {
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidContentType.selector, 3));
        vm.prank(owner);
        resolver.setABI(name1, 3, "");
    }

    function test_setABI_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_ABI,
                address(this)
            )
        );
        resolver.setABI(name1, 1, "");
    }

    function test_setInterface(bytes4 interfaceId, address impl) external {
        vm.expectEmit();
        emit IRecordResolver.InterfaceUpdated(1, interfaceId, impl, owner);
        vm.prank(owner);
        resolver.setInterface(name1, interfaceId, impl);

        assertEq(resolver.interfaceImplementer(node1, interfaceId), impl);
    }

    function test_setInterface_viaAddr() external {
        MockInterface c = new MockInterface();
        assertTrue(c.supportsInterface(TEST_SELECTOR));

        vm.prank(owner);
        resolver.setAddress(name1, COIN_TYPE_ETH, abi.encodePacked(c));

        assertEq(resolver.interfaceImplementer(node1, TEST_SELECTOR), address(c));
    }

    function test_setInterface_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_INTERFACE,
                address(this)
            )
        );
        resolver.setInterface(name1, bytes4(0), address(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // Multicall
    ////////////////////////////////////////////////////////////////////////

    function test_multicall_setters(bool checked) external {
        bytes[] memory m = new bytes[](2);
        m[0] = abi.encodeCall(IResolverSetters.setName, (name1, TEST_STRING));
        m[1] = abi.encodeCall(IResolverSetters.setContentHash, (name2, testAddress));

        vm.prank(owner);
        if (checked) {
            resolver.multicallWithNodeCheck(keccak256("dne"), m);
        } else {
            resolver.multicall(m);
        }

        assertEq(resolver.name(node1), TEST_STRING, "name()");
        assertEq(resolver.contenthash(node2), testAddress, "contenthash()");
    }

    function test_multicall_setters_notAuthorized() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        bytes[] memory m = new bytes[](1);
        m[0] = abi.encodeCall(IResolverSetters.setName, (name1, TEST_STRING));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_NAME, // first error
                address(this)
            )
        );
        resolver.multicall(m);
    }

    function test_multicall_getters() external {
        bytes[] memory m = new bytes[](4);
        m[0] = abi.encodeCall(IResolverSetters.setAddress, (name1, COIN_TYPE_ETH, testAddress));
        m[1] = abi.encodeCall(IResolverSetters.setText, (name1, TEST_STRING, TEST_STRING));
        m[2] = abi.encodeCall(IResolverSetters.setName, (name1, TEST_STRING));
        m[3] = abi.encodeCall(IResolverSetters.setContentHash, (name1, testAddress));
        vm.prank(owner);
        resolver.multicall(m);

        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(IAddrResolver.addr, (node1));
        calls[1] = abi.encodeCall(ITextResolver.text, (node1, TEST_STRING));
        calls[2] = abi.encodeCall(INameResolver.name, (node1));
        calls[3] = abi.encodeCall(IContentHashResolver.contenthash, (node1));

        bytes[] memory answers = new bytes[](calls.length);
        answers[0] = abi.encode(testAddr);
        answers[1] = abi.encode(TEST_STRING);
        answers[2] = abi.encode(TEST_STRING);
        answers[3] = abi.encode(testAddress);

        assertEq(resolver.multicall(calls), answers);
    }

    function test_multicall_getters_withError() external {
        bytes[] memory m = new bytes[](1);
        m[0] = abi.encodeWithSelector(TEST_SELECTOR);

        vm.expectRevert();
        resolver.multicall(m);
    }

    ////////////////////////////////////////////////////////////////////////
    // Default Record
    ////////////////////////////////////////////////////////////////////////

    function test_default_setABI() external {
        vm.prank(owner);
        resolver.setABI(EMPTY_NAME, 1, testAddress);

        (uint256 contentType, bytes memory data) = resolver.ABI(keccak256("dne"), 1);

        assertEq(abi.encode(contentType, data), abi.encode(1, testAddress));
    }

    function test_default_setAddress() external {
        vm.prank(owner);
        resolver.setAddress(EMPTY_NAME, COIN_TYPE_ETH, testAddress);

        assertEq(resolver.addr(keccak256("dne"), COIN_TYPE_ETH), testAddress);
    }

    function test_default_setContentHash() external {
        vm.prank(owner);
        resolver.setContentHash(EMPTY_NAME, testAddress);

        assertEq(resolver.contenthash(keccak256("dne")), testAddress);
    }

    function test_default_setData() external {
        vm.prank(owner);
        resolver.setData(EMPTY_NAME, TEST_STRING, testAddress);

        assertEq(resolver.data(keccak256("dne"), TEST_STRING), testAddress);
    }

    function test_default_setInterface() external {
        vm.prank(owner);
        resolver.setInterface(EMPTY_NAME, TEST_SELECTOR, testAddr);

        assertEq(resolver.interfaceImplementer(keccak256("dne"), TEST_SELECTOR), testAddr);
    }

    function test_default_setName() external {
        vm.prank(owner);
        resolver.setName(EMPTY_NAME, TEST_STRING);

        assertEq(resolver.name(keccak256("dne")), TEST_STRING);
    }

    function test_default_setPubkey() external {
        vm.prank(owner);
        resolver.setPubkey(EMPTY_NAME, keccak256("x"), keccak256("y"));

        (bytes32 x, bytes32 y) = resolver.pubkey(keccak256("dne"));
        assertEq(abi.encode(x, y), abi.encode(keccak256("x"), keccak256("y")));
    }

    function test_default_setText() external {
        vm.prank(owner);
        resolver.setText(EMPTY_NAME, TEST_STRING, TEST_STRING);

        assertEq(resolver.text(keccak256("dne"), TEST_STRING), TEST_STRING);
    }

    ////////////////////////////////////////////////////////////////////////
    // Coarse-grained Permissions
    ////////////////////////////////////////////////////////////////////////

    function test_setContentHash_anyName() external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record

        // friend cannot change name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_CONTENTHASH,
                friend
            )
        );
        vm.prank(friend);
        resolver.setContentHash(name1, "A");

        // give friend setContentHash() on any record
        vm.prank(owner);
        resolver.authorizeRecordRoles(
            EMPTY_NAME,
            PermissionedResolverLib.ROLE_SET_CONTENTHASH,
            friend,
            true
        );

        // friend can change same setter of name1
        vm.prank(friend);
        resolver.setContentHash(name1, "B");

        // // friend can change same setter of name2
        vm.prank(friend);
        resolver.setContentHash(name1, "C");

        // friend cannot change other setters
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_NAME,
                friend
            )
        );
        vm.prank(friend);
        resolver.setName(name1, "D");
    }

    ////////////////////////////////////////////////////////////////////////
    // Fine-grained Permissions
    ////////////////////////////////////////////////////////////////////////

    function test_setText_anyName_anyPart(string calldata key) external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record 1
        vm.prank(owner);
        resolver.setName(name2, TEST_STRING); // ensure record 2

        // friend cannot change name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(name1, key, "A");

        // give friend setText(*) on any record
        vm.prank(owner);
        resolver.authorizeRecordRoles(
            EMPTY_NAME,
            PermissionedResolverLib.ROLE_SET_TEXT,
            friend,
            true
        );

        // friend can change same setter of name1
        vm.prank(friend);
        resolver.setText(name1, key, "B");

        // friend can change same setter of name2
        vm.prank(friend);
        resolver.setText(name2, key, "C");

        // friend can change diff setter of name2
        vm.prank(friend);
        resolver.setText(name2, string.concat("2", key), "D");
    }

    function test_setText_oneName_anyPart(string calldata key) external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record 1
        vm.prank(owner);
        resolver.setName(name2, TEST_STRING); // ensure record 2

        // friend cannot change name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(name1, key, "A");

        // give friend setText(*) on name1
        vm.prank(owner);
        resolver.authorizeRecordRoles(name1, PermissionedResolverLib.ROLE_SET_TEXT, friend, true);

        // friend can change diff setter of name1
        vm.prank(friend);
        resolver.setText(name1, string.concat("2", key), "B");

        // friend cannot change same setter of name2
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(2),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(name2, key, "C");
    }

    function test_setText_anyName_onePart(string calldata key) external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record 1
        vm.prank(owner);
        resolver.setName(name2, TEST_STRING); // ensure record 2

        // friend cannot change name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(name1, key, "A");

        // give friend setText(key) on any record
        vm.prank(owner);
        resolver.authorizeSetterRoles(
            abi.encodeCall(IResolverSetters.setText, (EMPTY_NAME, key, "<ignored>")),
            friend,
            true
        );

        // friend can change same setter of name1
        vm.prank(friend);
        resolver.setText(name1, key, "B");

        // friend can change same setter of name2
        vm.prank(friend);
        resolver.setText(name2, key, "C");

        // friend cannot change diff setter of name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(name1, string.concat("2", key), "D");
    }

    function test_setText_oneName_onePart(string calldata key) external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record 1
        vm.prank(owner);
        resolver.setName(name2, TEST_STRING); // ensure record 2

        // friend cannot change name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(name1, key, "A");

        // give friend setText(key) on name1
        vm.prank(owner);
        resolver.authorizeSetterRoles(
            abi.encodeCall(IResolverSetters.setText, (name1, key, "<ignored>")),
            friend,
            true
        );

        // friend can change same setter of name1
        vm.prank(friend);
        resolver.setText(name1, key, "B");

        // friend cannot change diff setter of name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(name1, string.concat("2", key), "D");

        // friend cannot change same setter of name2
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(2),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(name2, key, "E");
    }

    function test_setAddr_anyName_onePart(uint256 coinType) external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record 1
        vm.prank(owner);
        resolver.setName(name2, TEST_STRING); // ensure record 2

        // friend cannot change name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_ADDRESS,
                friend
            )
        );
        vm.prank(friend);
        resolver.setAddress(name1, coinType, hex"1111111111111111111111111111111111111111");

        // give friend setAddr(coinType) on any record
        vm.prank(owner);
        resolver.authorizeSetterRoles(
            abi.encodeCall(IResolverSetters.setAddress, (EMPTY_NAME, coinType, "<ignored>")),
            friend,
            true
        );

        // friend can change same setter of name1
        vm.prank(friend);
        resolver.setAddress(name1, coinType, hex"2222222222222222222222222222222222222222");

        // friend can change same setter of name2
        vm.prank(friend);
        resolver.setAddress(name2, coinType, hex"3333333333333333333333333333333333333333");

        // friend cannot change diff setter of name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_ADDRESS,
                friend
            )
        );
        vm.prank(friend);
        resolver.setAddress(name1, ~coinType, hex"4444444444444444444444444444444444444444");
    }

    function test_setAddr_oneName_onePart(uint256 coinType) external {
        vm.prank(owner);
        resolver.setName(name1, TEST_STRING); // ensure record 1
        vm.prank(owner);
        resolver.setName(name2, TEST_STRING); // ensure record 2

        // friend cannot change name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_ADDRESS,
                friend
            )
        );
        vm.prank(friend);
        resolver.setAddress(name1, coinType, hex"1111111111111111111111111111111111111111");

        // give friend setAddr(coinType) on any name
        vm.prank(owner);
        resolver.authorizeSetterRoles(
            abi.encodeCall(IResolverSetters.setAddress, (name1, coinType, "<ignored>")),
            friend,
            true
        );

        // friend can change same setter of name1
        vm.prank(friend);
        resolver.setAddress(name1, coinType, hex"2222222222222222222222222222222222222222");

        // friend cannot change diff setter of name1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_ADDRESS,
                friend
            )
        );
        vm.prank(friend);
        resolver.setAddress(name1, ~coinType, hex"3333333333333333333333333333333333333333");

        // friend cannot change same setter of name2
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(2),
                PermissionedResolverLib.ROLE_SET_ADDRESS,
                friend
            )
        );
        vm.prank(friend);
        resolver.setAddress(name2, coinType, hex"4444444444444444444444444444444444444444");
    }
}

contract MockUpgrade is UUPSUpgradeable {
    function getRecordCount() external pure returns (uint256) {
        return 12345678;
    }
    function _authorizeUpgrade(address) internal override {}
}

contract MockInterface is ERC165 {
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == TEST_SELECTOR || super.supportsInterface(interfaceId);
    }
}
