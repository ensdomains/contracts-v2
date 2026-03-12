// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {
    IRecordResolver,
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
    PERMISSIONED_RESOLVER_INTERFACE_ID,
    IRecordResolver,
    IRecordSetters,
    PermissionedResolverLib,
    IMulticallable,
    NameCoder,
    ENSIP19,
    COIN_TYPE_ETH,
    COIN_TYPE_DEFAULT
} from "~src/resolver/PermissionedResolver.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract PermissionedResolverTest is Test {
    uint256 constant DEFAULT_ROLES = EACBaseRolesLib.ALL_ROLES;

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
            resolver.supportsInterface(type(IRecordResolver).interfaceId),
            "IRecordResolver"
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
    }

    // ////////////////////////////////////////////////////////////////////////
    // // grantNameRoles(), grantTextRoles(), and grantAddrRoles()
    // ////////////////////////////////////////////////////////////////////////

    // function test_grantNameRoles() external {
    //     uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
    //     uint256 resource = PermissionedResolverLib.resource(NameCoder.namehash(testName, 0), 0);
    //     vm.expectEmit();
    //     emit PermissionedResolver.NamedResource(resource, testName);
    //     vm.prank(owner);
    //     resolver.grantNameRoles(testName, roleBitmap, friend);
    //     assertTrue(resolver.hasRoles(resource, roleBitmap, friend));
    // }

    // function test_grantNameRoles_notAuthorized() external {
    //     uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACCannotGrantRoles.selector,
    //             PermissionedResolverLib.resource(NameCoder.namehash(testName, 0), 0),
    //             roleBitmap,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.grantNameRoles(testName, roleBitmap, owner);
    // }

    // function test_grantTextRoles() external {
    //     uint256 resource = PermissionedResolverLib.resource(
    //         NameCoder.namehash(testName, 0),
    //         PermissionedResolverLib.textPart(testString)
    //     );
    //     vm.expectEmit();
    //     emit PermissionedResolver.NamedTextResource(
    //         resource,
    //         testName,
    //         keccak256(bytes(testString)),
    //         testString
    //     );
    //     vm.prank(owner);
    //     resolver.grantTextRoles(testName, testString, friend);
    //     assertTrue(resolver.hasRoles(resource, PermissionedResolverLib.ROLE_SET_TEXT, friend));
    // }

    // function test_grantTextRoles_notAuthorized() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACCannotGrantRoles.selector,
    //             PermissionedResolverLib.resource(NameCoder.namehash(testName, 0), 0),
    //             PermissionedResolverLib.ROLE_SET_TEXT,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.grantTextRoles(testName, testString, owner);
    // }

    // function test_grantAddrRoles(uint256 coinType) external {
    //     uint256 resource = PermissionedResolverLib.resource(
    //         NameCoder.namehash(testName, 0),
    //         PermissionedResolverLib.addrPart(coinType)
    //     );
    //     vm.expectEmit();
    //     emit PermissionedResolver.NamedAddrResource(resource, testName, coinType);
    //     vm.prank(owner);
    //     resolver.grantAddrRoles(testName, coinType, friend);
    //     assertTrue(resolver.hasRoles(resource, PermissionedResolverLib.ROLE_SET_ADDR, friend));
    // }

    // function test_grantAddrRoles_notAuthorized() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACCannotGrantRoles.selector,
    //             PermissionedResolverLib.resource(NameCoder.namehash(testName, 0), 0),
    //             PermissionedResolverLib.ROLE_SET_ADDR,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.grantAddrRoles(testName, 0, owner);
    // }

    // ////////////////////////////////////////////////////////////////////////
    // // revokeRoles() [corresponding to granters above]
    // ////////////////////////////////////////////////////////////////////////

    // function test_revokeRoles_name() external {
    //     uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
    //     vm.prank(owner);
    //     resolver.grantNameRoles(testName, roleBitmap, friend);
    //     vm.prank(owner);
    //     assertTrue(
    //         resolver.revokeRoles(
    //             PermissionedResolverLib.resource(NameCoder.namehash(testName, 0), 0),
    //             roleBitmap,
    //             friend
    //         )
    //     );
    // }

    // function test_revokeRoles_text() external {
    //     vm.prank(owner);
    //     resolver.grantTextRoles(testName, testString, friend);
    //     vm.prank(owner);
    //     assertTrue(
    //         resolver.revokeRoles(
    //             PermissionedResolverLib.resource(
    //                 NameCoder.namehash(testName, 0),
    //                 PermissionedResolverLib.textPart(testString)
    //             ),
    //             PermissionedResolverLib.ROLE_SET_TEXT,
    //             friend
    //         )
    //     );
    // }

    // function test_revokeRoles_addr() external {
    //     uint256 coinType = 0;
    //     vm.prank(owner);
    //     resolver.grantAddrRoles(testName, coinType, friend);
    //     vm.prank(owner);
    //     assertTrue(
    //         resolver.revokeRoles(
    //             PermissionedResolverLib.resource(
    //                 NameCoder.namehash(testName, 0),
    //                 PermissionedResolverLib.addrPart(coinType)
    //             ),
    //             PermissionedResolverLib.ROLE_SET_ADDR,
    //             friend
    //         )
    //     );
    // }

    ////////////////////////////////////////////////////////////////////////
    // createRecord(), updateRecord(), bindRecord(), and getRecordCount()
    ////////////////////////////////////////////////////////////////////////

    function test_createRecord() external {
        vm.expectEmit();
        emit IRecordResolver.RecordName(1, testNode, testName);
        vm.prank(owner);
        resolver.createRecord(testName, new bytes[](0));
    }

    function test_createRecord_withSetters() external {
        vm.expectEmit();
        emit IRecordResolver.NameUpdated(1, testString, owner);
        bytes[] memory m = _oneCall(abi.encodeCall(IRecordSetters.setName, (testString)));
        vm.prank(owner);
        resolver.createRecord(testName, m);
    }

    function test_createRecord_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                resolver.ROOT_RESOURCE(),
                PermissionedResolverLib.ROLE_RECORDS,
                address(this)
            )
        );
        resolver.createRecord(testName, new bytes[](0));
    }

    function test_updateRecord() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectEmit();
        emit IRecordResolver.NameUpdated(1, testString, owner);
        vm.prank(owner);
        resolver.updateRecord(
            recordId,
            _oneCall(abi.encodeCall(IRecordSetters.setName, (testString)))
        );
    }

    function test_updateRecord_notAuthorized() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_NAME,
                address(this)
            )
        );
        resolver.updateRecord(
            recordId,
            _oneCall(abi.encodeCall(IRecordSetters.setName, (testString)))
        );
    }

    function test_bindRecord() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        bytes memory name = NameCoder.encode("another.eth");
        vm.expectEmit();
        emit IRecordResolver.RecordName(recordId, NameCoder.namehash(name, 0), name);
        vm.prank(owner);
        resolver.bindRecord(name, recordId);
    }

    function test_bindRecord_invalidRecord() external {
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidRecord.selector));
        vm.prank(owner);
        resolver.bindRecord(testName, 1);
    }

    function test_getRecordCount() external {
        assertEq(resolver.getRecordCount(), 0, "before");
        vm.prank(owner);
        resolver.createRecord(testName, new bytes[](0));
        assertEq(resolver.getRecordCount(), 1, "after");
    }

    ////////////////////////////////////////////////////////////////////////
    // Standard Resolver Profiles
    ////////////////////////////////////////////////////////////////////////

    function test_setAddress(uint256 coinType, bytes memory a) external {
        if (ENSIP19.isEVMCoinType(coinType)) {
            a = vm.randomBool() ? vm.randomBytes(20) : new bytes(0);
        }
        vm.expectEmit();
        emit IRecordResolver.AddressUpdated(1, coinType, a, owner);
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _oneCall(abi.encodeCall(IRecordSetters.setAddress, (coinType, a)))
        );

        assertEq(resolver.addr(testNode, coinType), a);
    }

    function test_setAddress_fallback(uint32 chain) external {
        vm.assume(chain < COIN_TYPE_DEFAULT);
        bytes memory a = vm.randomBytes(20);
        uint256 coinType = chain == 1 ? COIN_TYPE_ETH : (COIN_TYPE_DEFAULT | chain);

        // set default address
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _oneCall(abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_DEFAULT, a)))
        );

        // get specific address
        assertEq(resolver.addr(testNode, coinType), a);
    }

    function test_setAddress_zeroEVM() external {
        assertFalse(resolver.hasAddr(testNode, COIN_TYPE_ETH));

        bytes[] memory m = _oneCall(
            abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, abi.encodePacked(address(0))))
        );
        vm.prank(owner);
        resolver.createRecord(testName, m);

        assertTrue(resolver.hasAddr(testNode, COIN_TYPE_ETH));
    }

    function test_setAddress_zeroEVM_fallbacks() external {
        bytes[] memory m = new bytes[](3);
        m[0] = abi.encodeCall(
            IRecordSetters.setAddress,
            (COIN_TYPE_DEFAULT, abi.encodePacked(address(1)))
        );
        m[1] = abi.encodeCall(
            IRecordSetters.setAddress,
            (COIN_TYPE_DEFAULT | 1, abi.encodePacked(address(0)))
        );
        m[2] = abi.encodeCall(
            IRecordSetters.setAddress,
            (COIN_TYPE_DEFAULT | 2, abi.encodePacked(address(2)))
        );
        vm.prank(owner);
        resolver.createRecord(testName, m);

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

    function test_setAddress_invalidEVM_tooShort() external {
        bytes memory v = new bytes(19);
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidEVMAddress.selector, v));
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _oneCall(abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, v)))
        );
    }

    function test_setAddress_invalidEVM_tooLong() external {
        bytes memory v = new bytes(21);
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidEVMAddress.selector, v));
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _oneCall(abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, v)))
        );
    }

    function test_setAddr_notAuthorized() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_ADDRESS,
                address(this)
            )
        );
        resolver.updateRecord(
            recordId,
            _oneCall(abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, "")))
        );
    }

    function test_setText(string calldata key, string calldata value) external {
        vm.expectEmit();
        emit IRecordResolver.TextUpdated(1, keccak256(bytes(key)), key, value, owner);
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _oneCall(abi.encodeCall(IRecordSetters.setText, (key, value)))
        );

        assertEq(resolver.text(testNode, key), value);
    }

    function test_setText_notAuthorized() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_TEXT,
                address(this)
            )
        );
        resolver.updateRecord(recordId, _oneCall(abi.encodeCall(IRecordSetters.setText, ("", ""))));
    }

    function test_setName(string calldata name) external {
        vm.expectEmit();
        emit IRecordResolver.NameUpdated(1, name, owner);
        vm.prank(owner);
        resolver.createRecord(testName, _oneCall(abi.encodeCall(IRecordSetters.setName, (name))));

        assertEq(resolver.name(testNode), name);
    }

    // function test_setName_notAuthorized() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_NAME,
    //             address(this)
    //         )
    //     );
    //     resolver.setName(testNode, "");
    // }

    // function test_setContenthash(bytes calldata v) external {
    //     vm.expectEmit();
    //     vm.prank(owner);
    //     emit IContentHashResolver.ContenthashChanged(testNode, v);
    //     resolver.setContenthash(testNode, v);

    //     assertEq(resolver.contenthash(testNode), v, "immediate");

    //     bytes memory result = resolver.resolve(
    //         testName,
    //         abi.encodeCall(IContentHashResolver.contenthash, (bytes32(0)))
    //     );
    //     assertEq(result, abi.encode(v), "extended");
    // }

    // function test_setContenthash_notAuthorized() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_CONTENTHASH,
    //             address(this)
    //         )
    //     );
    //     resolver.setContenthash(testNode, "");
    // }

    // function test_setPubkey(bytes32 x, bytes32 y) external {
    //     vm.expectEmit();
    //     emit IPubkeyResolver.PubkeyChanged(testNode, x, y);
    //     vm.prank(owner);
    //     resolver.setPubkey(testNode, x, y);

    //     (bytes32 x_, bytes32 y_) = resolver.pubkey(testNode);
    //     assertEq(abi.encode(x_, y_), abi.encode(x, y), "immediate");

    //     bytes memory result = resolver.resolve(
    //         testName,
    //         abi.encodeCall(IPubkeyResolver.pubkey, (bytes32(0)))
    //     );
    //     assertEq(result, abi.encode(x, y), "extended");
    // }

    // function test_setPubkey_notAuthorized() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_PUBKEY,
    //             address(this)
    //         )
    //     );
    //     resolver.setPubkey(testNode, 0, 0);
    // }

    // function test_setABI(uint8 bit, bytes calldata data) external {
    //     uint256 contentType = 1 << bit;

    //     vm.expectEmit();
    //     emit IABIResolver.ABIChanged(testNode, contentType);
    //     vm.prank(owner);
    //     resolver.setABI(testNode, contentType, data);

    //     uint256 contentTypes = ~uint256(0);
    //     (uint256 contentType_, bytes memory data_) = resolver.ABI(testNode, contentTypes);
    //     bytes memory expect = data.length > 0 ? abi.encode(contentType, data) : abi.encode(0, "");
    //     assertEq(abi.encode(contentType_, data_), expect, "immediate");

    //     bytes memory result = resolver.resolve(
    //         testName,
    //         abi.encodeCall(IABIResolver.ABI, (bytes32(0), contentTypes))
    //     );
    //     assertEq(result, expect, "extended");
    // }

    // function test_setABI_invalidContentType_noBits() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(IPermissionedResolver.InvalidContentType.selector, 0)
    //     );
    //     vm.prank(owner);
    //     resolver.setABI(testNode, 0, "");
    // }

    // function test_setABI_invalidContentType_manyBits() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(IPermissionedResolver.InvalidContentType.selector, 3)
    //     );
    //     vm.prank(owner);
    //     resolver.setABI(testNode, 3, "");
    // }

    // function test_setABI_notAuthorized() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_ABI,
    //             address(this)
    //         )
    //     );
    //     resolver.setABI(testNode, 1, "");
    // }

    // function test_setInterface(bytes4 interfaceId, address impl) external {
    //     vm.assume(!resolver.supportsInterface(interfaceId));

    //     vm.expectEmit();
    //     emit IInterfaceResolver.InterfaceChanged(testNode, interfaceId, impl);
    //     vm.prank(owner);
    //     resolver.setInterface(testNode, interfaceId, impl);

    //     assertEq(resolver.interfaceImplementer(testNode, interfaceId), impl, "immediate");

    //     bytes memory result = resolver.resolve(
    //         testName,
    //         abi.encodeCall(IInterfaceResolver.interfaceImplementer, (bytes32(0), interfaceId))
    //     );
    //     assertEq(result, abi.encode(impl), "extended");
    // }

    // function test_interfaceImplementer_overlap() external {
    //     vm.prank(owner);
    //     resolver.setAddr(testNode, COIN_TYPE_ETH, abi.encodePacked(resolver));

    //     I[] memory v = _supportedInterfaces();
    //     for (uint256 i; i < v.length; ++i) {
    //         assertEq(
    //             resolver.interfaceImplementer(testNode, v[i].interfaceId),
    //             address(resolver),
    //             v[i].name
    //         );
    //     }
    // }

    // function test_setInterface_notAuthorized() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_INTERFACE,
    //             address(this)
    //         )
    //     );
    //     resolver.setInterface(testNode, bytes4(0), address(0));
    // }

    // ////////////////////////////////////////////////////////////////////////
    // // Multicall
    // ////////////////////////////////////////////////////////////////////////

    // function test_multicall_setters(bool checked) external {
    //     bytes[] memory calls = new bytes[](2);
    //     calls[0] = abi.encodeCall(PermissionedResolver.setName, (testNode, testString));
    //     calls[1] = abi.encodeCall(PermissionedResolver.setContenthash, (testNode, testAddress));

    //     vm.prank(owner);
    //     if (checked) {
    //         resolver.multicallWithNodeCheck(keccak256("ignored"), calls);
    //     } else {
    //         resolver.multicall(calls);
    //     }

    //     assertEq(resolver.name(testNode), testString, "name()");
    //     assertEq(resolver.contenthash(testNode), testAddress, "contenthash()");
    // }

    // function test_multicall_setters_notAuthorized() external {
    //     bytes[] memory calls = new bytes[](2);
    //     calls[0] = abi.encodeCall(PermissionedResolver.setName, (testNode, ""));
    //     calls[1] = abi.encodeCall(PermissionedResolver.setContenthash, (testNode, testAddress));

    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_NAME, // first error
    //             address(this)
    //         )
    //     );
    //     resolver.multicall(calls);
    // }

    // function test_multicall_getters() external {
    //     vm.startPrank(owner);
    //     resolver.setAddr(testNode, testAddr);
    //     resolver.setText(testNode, testString, testString);
    //     resolver.setName(testNode, testString);
    //     resolver.setContenthash(testNode, testAddress);
    //     vm.stopPrank();

    //     bytes[] memory calls = new bytes[](4);
    //     calls[0] = abi.encodeCall(IAddrResolver.addr, (testNode));
    //     calls[1] = abi.encodeCall(ITextResolver.text, (testNode, testString));
    //     calls[2] = abi.encodeCall(INameResolver.name, (testNode));
    //     calls[3] = abi.encodeCall(IContentHashResolver.contenthash, (testNode));

    //     bytes[] memory answers = new bytes[](calls.length);
    //     answers[0] = abi.encode(testAddr);
    //     answers[1] = abi.encode(testString);
    //     answers[2] = abi.encode(testString);
    //     answers[3] = abi.encode(testAddress);

    //     bytes memory result = resolver.resolve(
    //         testName,
    //         abi.encodeCall(PermissionedResolver.multicall, (calls))
    //     );
    //     assertEq(result, abi.encode(answers));
    // }

    // function test_multicall_getters_partialError() external {
    //     vm.prank(owner);
    //     resolver.setName(testNode, testString);

    //     bytes4 selector = 0x12345678;

    //     bytes[] memory calls = new bytes[](2);
    //     calls[0] = abi.encodeCall(INameResolver.name, (testNode));
    //     calls[1] = abi.encodeWithSelector(selector, selector);

    //     bytes[] memory answers = new bytes[](calls.length);
    //     answers[0] = abi.encode(testString);
    //     answers[1] = abi.encodeWithSelector(
    //         IPermissionedResolver.UnsupportedResolverProfile.selector,
    //         selector
    //     );

    //     bytes memory result = resolver.resolve(
    //         testName,
    //         abi.encodeCall(PermissionedResolver.multicall, (calls))
    //     );
    //     assertEq(result, abi.encode(answers));
    // }

    // ////////////////////////////////////////////////////////////////////////
    // // Fine-grained Permissions
    // ////////////////////////////////////////////////////////////////////////

    // function test_setText_anyNode_onePart() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_TEXT,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.setText(testNode, testString, "A");

    //     vm.prank(owner);
    //     resolver.grantTextRoles(NameCoder.encode(""), testString, friend);

    //     vm.prank(friend);
    //     resolver.setText(testNode, testString, "B");

    //     vm.prank(friend);
    //     resolver.setText(~testNode, testString, "C");

    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_TEXT,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.setText(testNode, string.concat(testString, testString), "D");
    // }

    // function test_setText_oneNode_onePart() external {
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_TEXT,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.setText(testNode, testString, "A");

    //     vm.prank(owner);
    //     resolver.grantTextRoles(testName, testString, friend);

    //     vm.prank(friend);
    //     resolver.setText(testNode, testString, "B");

    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(~testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_TEXT,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.setText(~testNode, testString, "C");
    // }

    // function test_setAddr_anyNode_onePart() external {
    //     uint256 coinType = 0;
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_ADDR,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.setAddr(testNode, coinType, hex"01");

    //     vm.prank(owner);
    //     resolver.grantAddrRoles(NameCoder.encode(""), coinType, friend);

    //     vm.prank(friend);
    //     resolver.setAddr(testNode, coinType, hex"02");

    //     vm.prank(friend);
    //     resolver.setAddr(~testNode, coinType, hex"03");

    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_ADDR,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.setAddr(testNode, ~coinType, hex"04");
    // }

    // function test_setAddr_oneNode_onePart() external {
    //     uint256 coinType = 0;
    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_ADDR,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.setAddr(testNode, coinType, hex"01");

    //     vm.prank(owner);
    //     resolver.grantAddrRoles(testName, coinType, friend);

    //     vm.prank(friend);
    //     resolver.setAddr(testNode, coinType, hex"02");

    //     vm.expectRevert(
    //         abi.encodeWithSelector(
    //             IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
    //             PermissionedResolverLib.resource(~testNode, 0),
    //             PermissionedResolverLib.ROLE_SET_ADDR,
    //             friend
    //         )
    //     );
    //     vm.prank(friend);
    //     resolver.setAddr(~testNode, coinType, hex"03");
    // }

    function _oneCall(bytes memory v) internal pure returns (bytes[] memory m) {
        m = new bytes[](1);
        m[0] = v;
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
        return interfaceId == 0x12345678 || super.supportsInterface(interfaceId);
    }
}
