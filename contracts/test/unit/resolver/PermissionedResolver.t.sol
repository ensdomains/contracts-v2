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

bytes4 constant TEST_SELECTOR = 0x12345678;

contract PermissionedResolverTest is Test {
    uint256 constant DEFAULT_ROLES = EACBaseRolesLib.ALL_ROLES;

    MockHCAFactoryBasic hcaFactory;
    PermissionedResolver resolver;

    address owner = makeAddr("owner");
    address friend = makeAddr("friend");

    bytes testName;
    bytes32 testNode;
    address testAddr = makeAddr("test");
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

        console.logBytes4(PERMISSIONED_RESOLVER_INTERFACE_ID);
        console.logBytes4(RECORD_RESOLVER_INTERFACE_ID);
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
    // createRecord(), updateRecordById(), bindRecord()
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
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _toArray(abi.encodeCall(IRecordSetters.setName, (testString)))
        );
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

    function test_updateRecordById() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectEmit();
        emit IRecordResolver.NameUpdated(recordId, testString, owner);
        vm.prank(owner);
        resolver.updateRecordById(
            recordId,
            _toArray(abi.encodeCall(IRecordSetters.setName, (testString)))
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
        resolver.updateRecordById(
            recordId,
            _toArray(abi.encodeCall(IRecordSetters.setName, (testString)))
        );
    }

    function test_updateRecordByName() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectEmit();
        emit IRecordResolver.NameUpdated(recordId, testString, owner);
        vm.prank(owner);
        resolver.updateRecordByName(
            testName,
            _toArray(abi.encodeCall(IRecordSetters.setName, (testString)))
        );
    }

    function test_updateRecordByName_invalidName() external {
        vm.prank(owner);
        resolver.createRecord(testName, new bytes[](0));

        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidRecord.selector));
        resolver.updateRecordByName(
            NameCoder.encode("dne"),
            _toArray(abi.encodeCall(IRecordSetters.setName, (testString)))
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

    ////////////////////////////////////////////////////////////////////////
    // getRecordId() and getRecordCount()
    ////////////////////////////////////////////////////////////////////////

    function test_getRecordId() external {
        assertEq(resolver.getRecordId(testNode), 0);

        // create
        vm.prank(owner);
        resolver.createRecord(testName, new bytes[](0));
        assertEq(resolver.getRecordId(testNode), 1);

        // replace
        vm.prank(owner);
        resolver.createRecord(testName, new bytes[](0));
        assertEq(resolver.getRecordId(testNode), 2);

        // restore
        vm.prank(owner);
        resolver.bindRecord(testName, 1);
        assertEq(resolver.getRecordId(testNode), 1);
    }

    function test_getRecordCount() external {
        assertEq(resolver.getRecordCount(), 0);

        vm.prank(owner);
        resolver.createRecord(testName, new bytes[](0));
        assertEq(resolver.getRecordCount(), 1);

        vm.prank(owner);
        resolver.createRecord(testName, new bytes[](0));
        assertEq(resolver.getRecordCount(), 2);

        vm.prank(owner);
        resolver.createRecord(NameCoder.encode("abc"), new bytes[](0));
        assertEq(resolver.getRecordCount(), 3);
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
            _toArray(abi.encodeCall(IRecordSetters.setAddress, (coinType, a)))
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
            _toArray(abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_DEFAULT, a)))
        );

        // get specific address
        assertEq(resolver.addr(testNode, coinType), a);
    }

    function test_setAddress_zeroEVM() external {
        assertFalse(resolver.hasAddr(testNode, COIN_TYPE_ETH));

        vm.prank(owner);
        resolver.createRecord(
            testName,
            _toArray(
                abi.encodeCall(
                    IRecordSetters.setAddress,
                    (COIN_TYPE_ETH, abi.encodePacked(address(0)))
                )
            )
        );

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
            _toArray(abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, v)))
        );
    }

    function test_setAddress_invalidEVM_tooLong() external {
        bytes memory v = new bytes(21);
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidEVMAddress.selector, v));
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _toArray(abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, v)))
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
        resolver.updateRecordById(
            recordId,
            _toArray(abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, "")))
        );
    }

    function test_setText(string calldata key, string calldata value) external {
        vm.expectEmit();
        emit IRecordResolver.TextUpdated(1, keccak256(bytes(key)), key, value, owner);
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _toArray(abi.encodeCall(IRecordSetters.setText, (key, value)))
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
        resolver.updateRecordById(
            recordId,
            _toArray(abi.encodeCall(IRecordSetters.setText, ("", "")))
        );
    }

    function test_setName(string calldata name) external {
        vm.expectEmit();
        emit IRecordResolver.NameUpdated(1, name, owner);
        vm.prank(owner);
        resolver.createRecord(testName, _toArray(abi.encodeCall(IRecordSetters.setName, (name))));

        assertEq(resolver.name(testNode), name);
    }

    function test_setName_notAuthorized() external {
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
        resolver.updateRecordById(recordId, _toArray(abi.encodeCall(IRecordSetters.setName, (""))));
    }

    function test_setContentHash(bytes calldata v) external {
        vm.expectEmit();
        emit IRecordResolver.ContentHashUpdated(1, v, owner);
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _toArray(abi.encodeCall(IRecordSetters.setContentHash, (v)))
        );

        assertEq(resolver.contenthash(testNode), v);
    }

    function test_setContentHash_notAuthorized() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_CONTENTHASH,
                address(this)
            )
        );
        resolver.updateRecordById(
            recordId,
            _toArray(abi.encodeCall(IRecordSetters.setContentHash, ("")))
        );
    }

    function test_setPubkey(bytes32 x, bytes32 y) external {
        vm.expectEmit();
        emit IRecordResolver.PubkeyUpdated(1, x, y, owner);
        vm.prank(owner);
        resolver.createRecord(testName, _toArray(abi.encodeCall(IRecordSetters.setPubkey, (x, y))));

        (bytes32 x_, bytes32 y_) = resolver.pubkey(testNode);
        assertEq(abi.encode(x_, y_), abi.encode(x, y));
    }

    function test_setPubkey_notAuthorized() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_PUBKEY,
                address(this)
            )
        );
        resolver.updateRecordById(
            recordId,
            _toArray(abi.encodeCall(IRecordSetters.setPubkey, (0, 0)))
        );
    }

    function test_setABI(uint8 bit, bytes calldata data) external {
        uint256 contentType = 1 << bit;

        vm.expectEmit();
        emit IRecordResolver.ABIUpdated(1, contentType, owner);
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _toArray(abi.encodeCall(IRecordSetters.setABI, (contentType, data)))
        );

        uint256 contentTypes = ~uint256(0); // try them all
        (uint256 contentType_, bytes memory data_) = resolver.ABI(testNode, contentTypes);
        bytes memory expect = data.length > 0 ? abi.encode(contentType, data) : abi.encode(0, "");
        assertEq(abi.encode(contentType_, data_), expect);
    }

    function test_setABI_invalidContentType_noBits() external {
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidContentType.selector, 0));
        vm.prank(owner);
        resolver.createRecord(testName, _toArray(abi.encodeCall(IRecordSetters.setABI, (0, ""))));
    }

    function test_setABI_invalidContentType_multipleBits() external {
        vm.expectRevert(abi.encodeWithSelector(IRecordResolver.InvalidContentType.selector, 3));
        vm.prank(owner);
        resolver.createRecord(testName, _toArray(abi.encodeCall(IRecordSetters.setABI, (3, ""))));
    }

    function test_setABI_notAuthorized() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_ABI,
                address(this)
            )
        );
        resolver.updateRecordById(
            recordId,
            _toArray(abi.encodeCall(IRecordSetters.setABI, (1, "")))
        );
    }

    function test_setInterface(bytes4 interfaceId, address impl) external {
        vm.expectEmit();
        emit IRecordResolver.InterfaceUpdated(1, interfaceId, impl, owner);
        vm.prank(owner);
        resolver.createRecord(
            testName,
            _toArray(abi.encodeCall(IRecordSetters.setInterface, (interfaceId, impl)))
        );

        assertEq(resolver.interfaceImplementer(testNode, interfaceId), impl);
    }

    function test_setInterface_viaAddr() external {
        MockInterface c = new MockInterface();
        assertTrue(c.supportsInterface(TEST_SELECTOR));

        vm.prank(owner);
        resolver.createRecord(
            testName,
            _toArray(
                abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, abi.encodePacked(c)))
            )
        );

        assertEq(resolver.interfaceImplementer(testNode, TEST_SELECTOR), address(c));
    }

    function test_setInterface_notAuthorized() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_INTERFACE,
                address(this)
            )
        );
        resolver.updateRecordById(
            recordId,
            _toArray(abi.encodeCall(IRecordSetters.setInterface, (bytes4(0), address(0))))
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Multicall
    ////////////////////////////////////////////////////////////////////////

    function test_multicall_setters(bool checked) external {
        bytes[] memory m = new bytes[](2);
        m[0] = abi.encodeCall(
            PermissionedResolver.createRecord,
            (testName, _toArray(abi.encodeCall(IRecordSetters.setName, (testString))))
        );
        m[1] = abi.encodeCall(
            PermissionedResolver.updateRecordByName,
            (testName, _toArray(abi.encodeCall(IRecordSetters.setContentHash, (testAddress))))
        );

        vm.prank(owner);
        if (checked) {
            resolver.multicallWithNodeCheck(keccak256("ignored"), m);
        } else {
            resolver.multicall(m);
        }

        assertEq(resolver.name(testNode), testString, "name()");
        assertEq(resolver.contenthash(testNode), testAddress, "contenthash()");
    }

    function test_multicall_setters_notAuthorized() external {
        vm.prank(owner);
        uint256 recordId = resolver.createRecord(testName, new bytes[](0));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_NAME, // first error
                address(this)
            )
        );
        resolver.multicall(
            _toArray(
                abi.encodeCall(
                    PermissionedResolver.updateRecordById,
                    (recordId, _toArray(abi.encodeCall(IRecordSetters.setName, (testString))))
                )
            )
        );
    }

    function test_multicall_getters() external {
        bytes[] memory m = new bytes[](4);
        m[0] = abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, testAddress));
        m[1] = abi.encodeCall(IRecordSetters.setText, (testString, testString));
        m[2] = abi.encodeCall(IRecordSetters.setName, (testString));
        m[3] = abi.encodeCall(IRecordSetters.setContentHash, (testAddress));
        vm.prank(owner);
        resolver.createRecord(testName, m);

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

        assertEq(resolver.multicall(calls), answers);
    }

    function test_multicall_getters_withError() external {
        vm.expectRevert();
        resolver.multicall(_toArray(abi.encodeWithSelector(TEST_SELECTOR)));
    }

    ////////////////////////////////////////////////////////////////////////
    // Default (recordId = 0)
    ////////////////////////////////////////////////////////////////////////

    function test_default_setAddress() external {
        vm.prank(owner);
        resolver.updateRecordById(
            0,
            _toArray(abi.encodeCall(IRecordSetters.setAddress, (COIN_TYPE_ETH, testAddress)))
        );

        assertEq(resolver.addr(keccak256("dne"), COIN_TYPE_ETH), testAddress);
    }

    function test_default_setText() external {
        vm.prank(owner);
        resolver.updateRecordById(
            0,
            _toArray(abi.encodeCall(IRecordSetters.setText, (testString, testString)))
        );

        assertEq(resolver.text(keccak256("dne"), testString), testString);
    }

    ////////////////////////////////////////////////////////////////////////
    // Fine-grained Permissions
    ////////////////////////////////////////////////////////////////////////

    function test_setText_anyNode_onePart() external {
        vm.prank(owner);
        uint256 recordId1 = resolver.createRecord(NameCoder.encode("1"), new bytes[](0));
        vm.prank(owner);
        uint256 recordId2 = resolver.createRecord(NameCoder.encode("2"), new bytes[](0));

        // friend cannot change record1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId1, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.updateRecordById(
            recordId1,
            _toArray(abi.encodeCall(IRecordSetters.setText, (testString, "A")))
        );

        // give friend setText(testString) on any record
        vm.prank(owner);
        resolver.grantSetterRoles(
            0,
            abi.encodeCall(IRecordSetters.setText, (testString, "")),
            friend
        );

        // friend can change record1
        vm.prank(friend);
        resolver.updateRecordById(
            recordId1,
            _toArray(abi.encodeCall(IRecordSetters.setText, (testString, "B")))
        );

        // friend can change record2
        vm.prank(friend);
        resolver.updateRecordById(
            recordId2,
            _toArray(abi.encodeCall(IRecordSetters.setText, (testString, "C")))
        );

        // friend cannot change record1 with different key
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId1, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.updateRecordById(
            recordId1,
            _toArray(
                abi.encodeCall(IRecordSetters.setText, (string.concat(testString, testString), "D"))
            )
        );
    }

    function test_setText_oneNode_onePart() external {
        vm.prank(owner);
        uint256 recordId1 = resolver.createRecord(NameCoder.encode("1"), new bytes[](0));
        vm.prank(owner);
        uint256 recordId2 = resolver.createRecord(NameCoder.encode("2"), new bytes[](0));

        // friend cannot change record1
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId1, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.updateRecordById(
            recordId1,
            _toArray(abi.encodeCall(IRecordSetters.setText, (testString, "A")))
        );

        // give friend setText(textString) on record1
        vm.prank(owner);
        resolver.grantSetterRoles(
            recordId1,
            abi.encodeCall(IRecordSetters.setText, (testString, "")),
            friend
        );

        // friend can change record1
        vm.prank(friend);
        resolver.updateRecordById(
            recordId1,
            _toArray(abi.encodeCall(IRecordSetters.setText, (testString, "B")))
        );

        // friend cannot change record with different key
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId1, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.updateRecordById(
            recordId1,
            _toArray(
                abi.encodeCall(IRecordSetters.setText, (string.concat(testString, testString), "D"))
            )
        );

        // friend cannot change record2 with same key
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(recordId2, PermissionedResolverLib.ANY_PART),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.updateRecordById(
            recordId2,
            _toArray(abi.encodeCall(IRecordSetters.setText, (testString, "E")))
        );
    }

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

    function _toArray(bytes memory v) internal pure returns (bytes[] memory m) {
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
        return interfaceId == TEST_SELECTOR || super.supportsInterface(interfaceId);
    }
}
