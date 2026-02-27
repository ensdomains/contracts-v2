// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {
    PermissionedResolver,
    PermissionedResolverLib,
    IMulticallable,
    IABIResolver,
    IAddrResolver,
    IAddressResolver,
    IContentHashResolver,
    IExtendedResolver,
    IHasAddressResolver,
    IInterfaceResolver,
    INameResolver,
    IPubkeyResolver,
    ITextResolver,
    IVersionableResolver,
    NameCoder,
    ResolverFeatures,
    IERC7996,
    ENSIP19,
    COIN_TYPE_ETH,
    COIN_TYPE_DEFAULT
} from "~src/resolver/PermissionedResolver.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract PermissionedResolverTest is Test {
    uint256 constant DEFAULT_ROLES = EACBaseRolesLib.ALL_ROLES;

    struct I {
        bytes4 interfaceId;
        string name;
    }
    function _supportedInterfaces() internal pure returns (I[] memory v) {
        uint256 i;
        v = new I[](15);
        v[i++] = I(type(IExtendedResolver).interfaceId, "IExtendedResolver");
        v[i++] = I(type(IERC7996).interfaceId, "IERC7996");
        v[i++] = I(type(IMulticallable).interfaceId, "IMulticallable");
        v[i++] = I(type(IABIResolver).interfaceId, "IABIResolver");
        v[i++] = I(type(IAddrResolver).interfaceId, "IAddrResolver");
        v[i++] = I(type(IAddressResolver).interfaceId, "IAddressResolver");
        v[i++] = I(type(IContentHashResolver).interfaceId, "IContentHashResolver");
        v[i++] = I(type(IHasAddressResolver).interfaceId, "IHasAddressResolver");
        v[i++] = I(type(IInterfaceResolver).interfaceId, "IInterfaceResolver");
        v[i++] = I(type(INameResolver).interfaceId, "INameResolver");
        v[i++] = I(type(IPubkeyResolver).interfaceId, "IPubkeyResolver");
        v[i++] = I(type(ITextResolver).interfaceId, "ITextResolver");
        v[i++] = I(type(IVersionableResolver).interfaceId, "IVersionableResolver");
        v[i++] = I(type(UUPSUpgradeable).interfaceId, "UUPSUpgradeable");
        v[i++] = I(type(IEnhancedAccessControl).interfaceId, "IEnhancedAccessControl");
        assertEq(v.length, i);
    }

    MockHCAFactoryBasic hcaFactory;
    PermissionedResolver resolver;

    address owner = makeAddr("owner");
    address friend = makeAddr("friend");

    bytes testName;
    bytes32 testNode;
    address testAddr = 0x8000000000000000000000000000000000000001;
    bytes testAddress = abi.encodePacked(testAddr);
    string testString = "abc";

    function setUp() external {
        VerifiableFactory factory = new VerifiableFactory();
        hcaFactory = new MockHCAFactoryBasic();
        PermissionedResolver resolverImpl = new PermissionedResolver(hcaFactory);
        testName = NameCoder.encode("test.eth");
        testNode = NameCoder.namehash(testName, 0);

        bytes memory initData = abi.encodeCall(
            PermissionedResolver.initialize,
            (owner, DEFAULT_ROLES)
        );
        resolver = PermissionedResolver(
            factory.deployProxy(address(resolverImpl), uint256(keccak256(initData)), initData)
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Init
    ////////////////////////////////////////////////////////////////////////

    function test_constructor() external view {
        assertEq(address(resolver.HCA_FACTORY()), address(hcaFactory), "HCA_FACTORY");
    }

    function test_initialize() external view {
        assertTrue(resolver.hasRootRoles(DEFAULT_ROLES, owner), "roles");
    }

    function test_upgrade() external {
        MockUpgrade upgrade = new MockUpgrade();
        vm.prank(owner);
        resolver.upgradeToAndCall(address(upgrade), "");
        assertEq(resolver.addr(testNode), upgrade.addr(testNode));
    }

    function test_upgrade_noRole() external {
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
        assertTrue(ERC165Checker.supportsERC165(address(resolver)), "ERC165");
        I[] memory v = _supportedInterfaces();
        for (uint256 i; i < v.length; i++) {
            assertTrue(
                ERC165Checker.supportsInterface(address(resolver), v[i].interfaceId),
                v[i].name
            );
        }
    }

    function test_supportsFeature() external view {
        assertTrue(
            resolver.supportsFeature(ResolverFeatures.RESOLVE_MULTICALL),
            "RESOLVE_MULTICALL"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // setAlias() and getAlias()
    ////////////////////////////////////////////////////////////////////////

    function test_alias_none() external view {
        assertEq(resolver.getAlias(NameCoder.encode("test.eth")), "", "test");
        assertEq(resolver.getAlias(NameCoder.encode("")), "", "root");
        assertEq(resolver.getAlias(NameCoder.encode("xyz")), "", "xyz");
    }

    function test_alias_root() external {
        vm.prank(owner);
        vm.expectEmit();
        emit PermissionedResolver.AliasChanged(
            NameCoder.encode(""),
            NameCoder.encode("test.eth"),
            NameCoder.encode(""),
            NameCoder.encode("test.eth")
        );
        resolver.setAlias(NameCoder.encode(""), NameCoder.encode("test.eth"));

        assertEq(resolver.getAlias(NameCoder.encode("")), NameCoder.encode("test.eth"), "root");
        assertEq(
            resolver.getAlias(NameCoder.encode("sub")),
            NameCoder.encode("sub.test.eth"),
            "sub"
        );
    }

    function test_alias_exact() external {
        vm.prank(owner);
        resolver.setAlias(NameCoder.encode("other.eth"), NameCoder.encode("test.eth"));

        assertEq(
            resolver.getAlias(NameCoder.encode("other.eth")),
            NameCoder.encode("test.eth"),
            "exact"
        );
    }

    function test_alias_subdomain() external {
        vm.prank(owner);
        resolver.setAlias(NameCoder.encode("com"), NameCoder.encode("eth"));

        assertEq(resolver.getAlias(NameCoder.encode("com")), NameCoder.encode("eth"), "exact");
        assertEq(
            resolver.getAlias(NameCoder.encode("test.com")),
            NameCoder.encode("test.eth"),
            "alias"
        );
    }

    function test_alias_recursive() external {
        vm.startPrank(owner);
        resolver.setAlias(NameCoder.encode("ens.xyz"), NameCoder.encode("com"));
        resolver.setAlias(NameCoder.encode("com"), NameCoder.encode("eth"));
        vm.stopPrank();

        assertEq(
            resolver.getAlias(NameCoder.encode("test.ens.xyz")),
            NameCoder.encode("test.eth"),
            "alias"
        );
    }

    function test_alias_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                resolver.ROOT_RESOURCE(),
                PermissionedResolverLib.ROLE_SET_ALIAS,
                address(this)
            )
        );
        resolver.setAlias(testName, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // grantNameRoles(), grantTextRoles(), and grantAddrRoles()
    ////////////////////////////////////////////////////////////////////////

    function test_grantNameRoles() external {
        uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
        uint256 resource = PermissionedResolverLib.resource(NameCoder.namehash(testName, 0), 0);
        vm.expectEmit();
        emit PermissionedResolver.NamedResource(resource, testName);
        vm.prank(owner);
        resolver.grantNameRoles(testName, roleBitmap, friend);
        assertTrue(resolver.hasRoles(resource, roleBitmap, friend));
    }

    function test_grantNameRoles_notAuthorized() external {
        uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                uint256(NameCoder.namehash(testName, 0)),
                roleBitmap,
                friend
            )
        );
        vm.prank(friend);
        resolver.grantNameRoles(testName, roleBitmap, owner);
    }

    function test_grantTextRoles() external {
        uint256 resource = PermissionedResolverLib.resource(
            NameCoder.namehash(testName, 0),
            PermissionedResolverLib.textPart(testString)
        );
        vm.expectEmit();
        emit PermissionedResolver.NamedTextResource(
            resource,
            testName,
            keccak256(bytes(testString)),
            testString
        );
        vm.prank(owner);
        resolver.grantTextRoles(testName, testString, friend);
        assertTrue(resolver.hasRoles(resource, PermissionedResolverLib.ROLE_SET_TEXT, friend));
    }

    function test_grantTextRoles_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                uint256(NameCoder.namehash(testName, 0)),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.grantTextRoles(testName, testString, owner);
    }

    function test_grantAddrRoles(uint256 coinType) external {
        uint256 resource = PermissionedResolverLib.resource(
            NameCoder.namehash(testName, 0),
            PermissionedResolverLib.addrPart(coinType)
        );
        vm.expectEmit();
        emit PermissionedResolver.NamedAddrResource(resource, testName, coinType);
        vm.prank(owner);
        resolver.grantAddrRoles(testName, coinType, friend);
        assertTrue(resolver.hasRoles(resource, PermissionedResolverLib.ROLE_SET_ADDR, friend));
    }

    function test_grantAddrRoles_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                uint256(NameCoder.namehash(testName, 0)),
                PermissionedResolverLib.ROLE_SET_ADDR,
                friend
            )
        );
        vm.prank(friend);
        resolver.grantAddrRoles(testName, 0, owner);
    }

    function test_revokeRoles() external {}

    ////////////////////////////////////////////////////////////////////////
    // Standard Resolver Profiles
    ////////////////////////////////////////////////////////////////////////

    function test_versions() external {
        uint64 version = resolver.recordVersions(testNode);
        assertEq(version, 0, "before");

        ++version;
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IVersionableResolver.VersionChanged(testNode, version);
        resolver.clearRecords(testNode);

        assertEq(resolver.recordVersions(testNode), version, "after");
    }

    function test_setAddr(address a) external {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAddrResolver.AddrChanged(testNode, a);
        resolver.setAddr(testNode, a);

        assertEq(resolver.addr(testNode), a, "immediate");

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(IAddrResolver.addr, (bytes32(0)))
        );
        assertEq(result, abi.encode(a), "extended");
    }

    function test_setAddr(uint256 coinType, bytes memory a) external {
        if (ENSIP19.isEVMCoinType(coinType)) {
            a = vm.randomBool() ? vm.randomBytes(20) : new bytes(0);
        }
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IAddressResolver.AddressChanged(testNode, coinType, a);
        resolver.setAddr(testNode, coinType, a);

        assertEq(resolver.addr(testNode, coinType), a, "immediate");

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(IAddressResolver.addr, (bytes32(0), coinType))
        );
        assertEq(result, abi.encode(a), "extended");
    }

    function test_setAddr_fallback(uint32 chain) external {
        vm.assume(chain < COIN_TYPE_DEFAULT);
        bytes memory a = vm.randomBytes(20);
        uint256 coinType = chain == 1 ? COIN_TYPE_ETH : (COIN_TYPE_DEFAULT | chain);

        vm.prank(owner);
        resolver.setAddr(testNode, COIN_TYPE_DEFAULT, a);

        assertEq(resolver.addr(testNode, coinType), a);
    }

    function test_setAddr_zeroEVM() external {
        vm.prank(owner);
        resolver.setAddr(testNode, COIN_TYPE_ETH, abi.encodePacked(address(0)));

        assertTrue(resolver.hasAddr(testNode, COIN_TYPE_ETH), "null");
        assertFalse(resolver.hasAddr(testNode, COIN_TYPE_DEFAULT), "unset");

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), COIN_TYPE_ETH))
        );
        assertEq(result, abi.encode(true), "extended");
    }

    function test_setAddr_zeroEVM_fallbacks() external {
        vm.startPrank(owner);
        resolver.setAddr(testNode, COIN_TYPE_DEFAULT, abi.encodePacked(address(1)));
        resolver.setAddr(testNode, COIN_TYPE_DEFAULT | 1, abi.encodePacked(address(0)));
        resolver.setAddr(testNode, COIN_TYPE_DEFAULT | 2, abi.encodePacked(address(2)));
        vm.stopPrank();

        assertEq(
            resolver.addr(testNode, COIN_TYPE_DEFAULT | 1),
            abi.encodePacked(address(0)),
            "block"
        );
        assertEq(
            resolver.addr(testNode, COIN_TYPE_DEFAULT | 2),
            abi.encodePacked(address(2)),
            "override"
        );
        assertEq(
            resolver.addr(testNode, COIN_TYPE_DEFAULT | 3),
            abi.encodePacked(address(1)),
            "fallback"
        );
    }

    function test_setAddr_invalidEVM_tooShort() external {
        bytes memory v = new bytes(19);
        vm.expectRevert(abi.encodeWithSelector(PermissionedResolver.InvalidEVMAddress.selector, v));
        vm.prank(owner);
        resolver.setAddr(testNode, COIN_TYPE_ETH, v);
    }

    function test_setAddr_invalidEVM_tooLong() external {
        bytes memory v = new bytes(21);
        vm.expectRevert(abi.encodeWithSelector(PermissionedResolver.InvalidEVMAddress.selector, v));
        vm.prank(owner);
        resolver.setAddr(testNode, COIN_TYPE_ETH, v);
    }

    function test_setAddr_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_ADDR,
                address(this)
            )
        );
        resolver.setAddr(testNode, COIN_TYPE_ETH, "");
    }

    function test_setText(string calldata key, string calldata value) external {
        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit ITextResolver.TextChanged(testNode, key, key, value);
        resolver.setText(testNode, key, value);

        assertEq(resolver.text(testNode, key), value, "immediate");

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(ITextResolver.text, (bytes32(0), key))
        );
        assertEq(result, abi.encode(value), "extended");
    }

    function test_setText_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_TEXT,
                address(this)
            )
        );
        resolver.setText(testNode, testString, "");
    }

    function test_setName(string calldata name) external {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit INameResolver.NameChanged(testNode, name);
        resolver.setName(testNode, name);

        assertEq(resolver.name(testNode), name, "immediate");

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(INameResolver.name, (bytes32(0)))
        );
        assertEq(result, abi.encode(name), "extended");
    }

    function test_setName_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_NAME,
                address(this)
            )
        );
        resolver.setName(testNode, "");
    }

    function test_setContenthash(bytes calldata v) external {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IContentHashResolver.ContenthashChanged(testNode, v);
        resolver.setContenthash(testNode, v);

        assertEq(resolver.contenthash(testNode), v, "immediate");

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(IContentHashResolver.contenthash, (bytes32(0)))
        );
        assertEq(result, abi.encode(v), "extended");
    }

    function test_setContenthash_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_CONTENTHASH,
                address(this)
            )
        );
        resolver.setContenthash(testNode, "");
    }

    function test_setPubkey(bytes32 x, bytes32 y) external {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit IPubkeyResolver.PubkeyChanged(testNode, x, y);
        resolver.setPubkey(testNode, x, y);

        (bytes32 x_, bytes32 y_) = resolver.pubkey(testNode);
        assertEq(abi.encode(x_, y_), abi.encode(x, y), "immediate");

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(IPubkeyResolver.pubkey, (bytes32(0)))
        );
        assertEq(result, abi.encode(x, y), "extended");
    }

    function test_setPubkey_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_PUBKEY,
                address(this)
            )
        );
        resolver.setPubkey(testNode, 0, 0);
    }

    function test_setABI(uint8 bit, bytes calldata data) external {
        uint256 contentType = 1 << bit;

        vm.prank(owner);
        vm.expectEmit(true, true, false, false);
        emit IABIResolver.ABIChanged(testNode, contentType);
        resolver.setABI(testNode, contentType, data);

        uint256 contentTypes = ~uint256(0);
        (uint256 contentType_, bytes memory data_) = resolver.ABI(testNode, contentTypes);
        bytes memory expect = data.length > 0 ? abi.encode(contentType, data) : abi.encode(0, "");
        assertEq(abi.encode(contentType_, data_), expect, "immediate");

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(IABIResolver.ABI, (bytes32(0), contentTypes))
        );
        assertEq(result, expect, "extended");
    }

    function test_setABI_invalidContentType_noBits() external {
        vm.expectRevert(
            abi.encodeWithSelector(PermissionedResolver.InvalidContentType.selector, 0)
        );
        vm.prank(owner);
        resolver.setABI(testNode, 0, "");
    }

    function test_setABI_invalidContentType_manyBits() external {
        vm.expectRevert(
            abi.encodeWithSelector(PermissionedResolver.InvalidContentType.selector, 3)
        );
        vm.prank(owner);
        resolver.setABI(testNode, 3, "");
    }

    function test_setABI_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_ABI,
                address(this)
            )
        );
        resolver.setABI(testNode, 1, "");
    }

    function test_setInterface(bytes4 interfaceId, address impl) external {
        vm.assume(!resolver.supportsInterface(interfaceId));

        vm.prank(owner);
        vm.expectEmit(true, true, false, true);
        emit IInterfaceResolver.InterfaceChanged(testNode, interfaceId, impl);
        resolver.setInterface(testNode, interfaceId, impl);

        assertEq(resolver.interfaceImplementer(testNode, interfaceId), impl, "immediate");

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(IInterfaceResolver.interfaceImplementer, (bytes32(0), interfaceId))
        );
        assertEq(result, abi.encode(impl), "extended");
    }

    function test_interfaceImplementer_overlap() external {
        vm.prank(owner);
        resolver.setAddr(testNode, COIN_TYPE_ETH, abi.encodePacked(resolver));

        I[] memory v = _supportedInterfaces();
        for (uint256 i; i < v.length; ++i) {
            assertEq(
                resolver.interfaceImplementer(testNode, v[i].interfaceId),
                address(resolver),
                v[i].name
            );
        }
    }

    function test_setInterface_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_INTERFACE,
                address(this)
            )
        );
        resolver.setInterface(testNode, bytes4(0), address(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // Multicall
    ////////////////////////////////////////////////////////////////////////

    function test_multicall_setters(bool checked) external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PermissionedResolver.setName, (testNode, testString));
        calls[1] = abi.encodeCall(PermissionedResolver.setContenthash, (testNode, testAddress));

        vm.prank(owner);
        if (checked) {
            resolver.multicallWithNodeCheck(keccak256("ignored"), calls);
        } else {
            resolver.multicall(calls);
        }

        assertEq(resolver.name(testNode), testString, "name()");
        assertEq(resolver.contenthash(testNode), testAddress, "contenthash()");
    }

    function test_multicall_setters_notAuthorized() external {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PermissionedResolver.setName, (testNode, ""));
        calls[1] = abi.encodeCall(PermissionedResolver.setContenthash, (testNode, testAddress));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_NAME, // first error
                address(this)
            )
        );
        resolver.multicall(calls);
    }

    function test_multicall_getters() external {
        vm.startPrank(owner);
        resolver.setAddr(testNode, testAddr);
        resolver.setText(testNode, testString, testString);
        resolver.setName(testNode, testString);
        resolver.setContenthash(testNode, testAddress);
        vm.stopPrank();

        bytes[] memory calls = new bytes[](4);
        calls[0] = abi.encodeCall(IAddrResolver.addr, (testNode));
        calls[1] = abi.encodeCall(ITextResolver.text, (testNode, testString));
        calls[2] = abi.encodeCall(INameResolver.name, (testNode));
        calls[3] = abi.encodeCall(IContentHashResolver.contenthash, (testNode));

        bytes[] memory answers = new bytes[](calls.length);
        answers[0] = abi.encode(testAddr);
        answers[1] = abi.encode(testString);
        answers[2] = abi.encode(testString);
        answers[3] = abi.encode(testAddress);

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(PermissionedResolver.multicall, (calls))
        );
        assertEq(result, abi.encode(answers));
    }

    function test_multicall_getters_partialError() external {
        vm.prank(owner);
        resolver.setName(testNode, testString);

        bytes4 selector = 0x12345678;

        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(INameResolver.name, (testNode));
        calls[1] = abi.encodeWithSelector(selector, selector);

        bytes[] memory answers = new bytes[](calls.length);
        answers[0] = abi.encode(testString);
        answers[1] = abi.encodeWithSelector(
            PermissionedResolver.UnsupportedResolverProfile.selector,
            selector
        );

        bytes memory result = resolver.resolve(
            testName,
            abi.encodeCall(PermissionedResolver.multicall, (calls))
        );
        assertEq(result, abi.encode(answers));
    }

    ////////////////////////////////////////////////////////////////////////
    // Fine-grained Permissions
    ////////////////////////////////////////////////////////////////////////

    function test_setText_anyNode_onePart() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(testNode, testString, "A");

        vm.prank(owner);
        resolver.grantTextRoles(NameCoder.encode(""), testString, friend);

        vm.prank(friend);
        resolver.setText(testNode, testString, "B");

        vm.prank(friend);
        resolver.setText(~testNode, testString, "C");

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(testNode, string.concat(testString, testString), "D");
    }

    function test_setText_oneNode_onePart() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(testNode, testString, "A");

        vm.prank(owner);
        resolver.grantTextRoles(testName, testString, friend);

        vm.prank(friend);
        resolver.setText(testNode, testString, "B");

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(~testNode, 0),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(~testNode, testString, "C");
    }

    function test_setAddr_anyNode_onePart() external {
        uint256 coinType = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_ADDR,
                friend
            )
        );
        vm.prank(friend);
        resolver.setAddr(testNode, coinType, hex"01");

        vm.prank(owner);
        resolver.grantAddrRoles(NameCoder.encode(""), coinType, friend);

        vm.prank(friend);
        resolver.setAddr(testNode, coinType, hex"02");

        vm.prank(friend);
        resolver.setAddr(~testNode, coinType, hex"03");

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_ADDR,
                friend
            )
        );
        vm.prank(friend);
        resolver.setAddr(testNode, ~coinType, hex"04");
    }

    function test_setAddr_oneNode_onePart() external {
        uint256 coinType = 0;
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_ADDR,
                friend
            )
        );
        vm.prank(friend);
        resolver.setAddr(testNode, coinType, hex"01");

        vm.prank(owner);
        resolver.grantAddrRoles(testName, coinType, friend);

        vm.prank(friend);
        resolver.setAddr(testNode, coinType, hex"02");

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(~testNode, 0),
                PermissionedResolverLib.ROLE_SET_ADDR,
                friend
            )
        );
        vm.prank(friend);
        resolver.setAddr(~testNode, coinType, hex"03");
    }
}

contract MockUpgrade is UUPSUpgradeable {
    function addr(bytes32) external pure returns (address) {
        return address(1);
    }
    function _authorizeUpgrade(address) internal override {}
}
