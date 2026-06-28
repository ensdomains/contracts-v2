// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {
    ENSIP19,
    CHAIN_ID_ETH,
    COIN_TYPE_ETH,
    COIN_TYPE_DEFAULT
} from "@ens/contracts/utils/ENSIP19.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";
import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";
import {IABIResolver} from "@ens/contracts/resolvers/profiles/IABIResolver.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IDataResolver} from "@ens/contracts/resolvers/profiles/IDataResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";
import {IInterfaceResolver} from "@ens/contracts/resolvers/profiles/IInterfaceResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {IPubkeyResolver} from "@ens/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";

import {IABISetter} from "~src/resolver/interfaces/setters/IABISetter.sol";
import {IAddressSetter} from "~src/resolver/interfaces/setters/IAddressSetter.sol";
import {IContentHashSetter} from "~src/resolver/interfaces/setters/IContentHashSetter.sol";
import {IDataSetter} from "~src/resolver/interfaces/setters/IDataSetter.sol";
import {IInterfaceSetter} from "~src/resolver/interfaces/setters/IInterfaceSetter.sol";
import {INameSetter} from "~src/resolver/interfaces/setters/INameSetter.sol";
import {IPubkeySetter} from "~src/resolver/interfaces/setters/IPubkeySetter.sol";
import {ITextSetter} from "~src/resolver/interfaces/setters/ITextSetter.sol";
import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {IPermissionedResolver} from "~src/resolver/interfaces/IPermissionedResolver.sol";
import {PermissionedResolverLib} from "~src/resolver/libraries/PermissionedResolverLib.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

bytes4 constant TEST_SELECTOR = 0x12345678;

bytes constant TEST_BYTES = hex"0123456789abcdef";

contract PermissionedResolverTest is V2Fixture {
    uint256 constant DEFAULT_ROLES = EACBaseRolesLib.ALL_ROLES;

    PermissionedResolver implementation;
    PermissionedResolver resolver;

    address owner = makeAddr("owner");
    address actor = makeAddr("actor");
    address friend = makeAddr("friend");

    bytes testName;
    bytes otherName;
    bytes dneName;
    bytes rootName;

    address testAddr = makeAddr("test");
    bytes testAddress = abi.encodePacked(testAddr);

    function setUp() external {
        deployV2Fixture();

        implementation = new PermissionedResolver(address(this));

        testName = NameCoder.encode("test.eth");
        otherName = NameCoder.encode("other.eth");
        dneName = NameCoder.encode("dne");
        rootName = NameCoder.encode("");

        bytes memory initData =
            abi.encodeCall(PermissionedResolver.initialize, (owner, DEFAULT_ROLES, new bytes[](0)));
        resolver = PermissionedResolver(
            verifiableFactory.deployProxy(
                address(implementation),
                uint256(keccak256(initData)),
                initData
            )
        );

        rootRegistry.setResolver(rootRegistry.findTokenId("eth"), address(resolver));
    }

    ////////////////////////////////////////////////////////////////////////
    // Init
    ////////////////////////////////////////////////////////////////////////

    function test_initialize() external view {
        assertTrue(resolver.hasRootRoles(DEFAULT_ROLES, owner));
    }

    function test_initialize_unowned() external {
        bytes memory initData =
            abi.encodeCall(PermissionedResolver.initialize, (address(0), 0, new bytes[](0)));
        PermissionedResolver r =
            PermissionedResolver(
                verifiableFactory.deployProxy(
                    address(implementation),
                    uint256(keccak256(initData)),
                    initData
                )
            );
        assertEq(r.roleCount(r.ROOT_RESOURCE()), 0);
    }

    function test_initalize_with_setters() external {
        bytes[] memory m = new bytes[](2);
        m[0] = abi.encodeCall(PermissionedResolver.setName, (testName, "NAME"));
        m[1] = abi.encodeCall(PermissionedResolver.setContentHash, (testName, TEST_BYTES));

        bytes memory initData = abi.encodeCall(PermissionedResolver.initialize, (address(0), 0, m));
        PermissionedResolver r =
            PermissionedResolver(
                verifiableFactory.deployProxy(
                    address(implementation),
                    uint256(keccak256(initData)),
                    initData
                )
            );

        assertEq(
            r.resolve(testName, abi.encodeCall(INameResolver.name, bytes32(0))),
            abi.encode("NAME"),
            "name"
        );
        assertEq(
            r.resolve(testName, abi.encodeCall(IContentHashResolver.contenthash, bytes32(0))),
            abi.encode(TEST_BYTES),
            "contenthash"
        );
    }

    function test_canUpgradeFrom() external view {
        assertTrue(resolver.canUpgradeFrom(address(0))); // accepts
        assertTrue(resolver.canUpgradeFrom(address(1))); // any address
    }

    function test_upgrade() external {
        MockUpgrade upgrade = new MockUpgrade();
        vm.prank(owner);
        resolver.upgradeToAndCall(address(upgrade), "");
        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddrResolver.addr, bytes32(0))),
            upgrade.resolve(testName, abi.encodeCall(IAddrResolver.addr, bytes32(0)))
        );
    }

    function test_upgrade_notAuthorized() external {
        MockUpgrade upgrade = new MockUpgrade();
        assertTrue(resolver.canUpgradeFrom(address(upgrade)));
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
            ERC165Checker.supportsInterface(
                address(resolver),
                type(IPermissionedResolver).interfaceId
            ),
            "IPermissionedResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(resolver),
                type(IEnhancedAccessControl).interfaceId
            ),
            "IEnhancedAccessControl"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IExtendedResolver).interfaceId),
            "IExtendedResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IContractNamer).interfaceId),
            "IContractNamer"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IMulticallable).interfaceId),
            "IMulticallable"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IERC7996).interfaceId),
            "IERC7996"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(UUPSUpgradeable).interfaceId),
            "UUPSUpgradeable"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IProxyAuthorization).interfaceId),
            "IProxyAuthorization"
        );

        // setters
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IABISetter).interfaceId),
            "IABISetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IAddressSetter).interfaceId),
            "IAddressSetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IContentHashSetter).interfaceId),
            "IContentHashSetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IDataSetter).interfaceId),
            "IDataSetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IInterfaceSetter).interfaceId),
            "IInterfaceSetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(INameSetter).interfaceId),
            "INameSetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IPubkeySetter).interfaceId),
            "IPubkeySetter"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(ITextSetter).interfaceId),
            "ITextSetter"
        );
    }

    function test_supportsFeature() external view {
        assertTrue(resolver.supportsFeature(ResolverFeatures.RESOLVE_MULTICALL));
    }

    ////////////////////////////////////////////////////////////////////////
    // link()
    ////////////////////////////////////////////////////////////////////////

    function test_unknownRecord() external {
        assertEq(resolver.getRecordId(NameCoder.namehash(testName, 0)), 0);
    }

    function test_ensureRecord() external {
        vm.prank(owner);
        resolver.setName(testName, "");
        assertEq(resolver.getRecordId(NameCoder.namehash(testName, 0)), 1);

        vm.prank(owner);
        resolver.setName(otherName, "");
        assertEq(resolver.getRecordId(NameCoder.namehash(otherName, 0)), 2);
    }

    function test_link() external {
        vm.prank(owner);
        resolver.setName(testName, "NAME");

        vm.expectEmit();
        emit IPermissionedResolver.Linked(NameCoder.namehash(otherName, 0), otherName, 1);
        vm.prank(owner);
        resolver.link(otherName, NameCoder.namehash(testName, 0));

        assertEq(
            resolver.getRecordId(NameCoder.namehash(testName, 0)),
            resolver.getRecordId(NameCoder.namehash(otherName, 0))
        );
        assertEq(
            resolver.resolve(otherName, abi.encodeCall(INameResolver.name, bytes32(0))),
            abi.encode("NAME")
        );
    }

    function test_link_unknownRecord() external {
        vm.expectRevert(abi.encodeWithSelector(IPermissionedResolver.InvalidRecord.selector));
        vm.prank(owner);
        resolver.link(testName, keccak256("dne"));
    }

    function test_link_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                resolver.ROOT_RESOURCE(),
                PermissionedResolverLib.ROLE_MANAGER,
                actor
            )
        );
        vm.prank(actor);
        resolver.link(testName, bytes32(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // clear()
    ////////////////////////////////////////////////////////////////////////

    function test_clear() external {
        vm.expectEmit();
        emit IPermissionedResolver.Linked(NameCoder.namehash(testName, 0), testName, 1);
        vm.prank(owner);
        resolver.clear(testName);

        vm.expectEmit();
        emit IPermissionedResolver.Linked(NameCoder.namehash(testName, 0), testName, 2);
        vm.prank(owner);
        resolver.clear(testName);
    }

    function test_clear_notAuthorized() external {
        // try without record
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(0),
                PermissionedResolverLib.ROLE_MANAGER,
                actor
            )
        );
        vm.prank(actor);
        resolver.clear(testName);

        // ensure record
        vm.prank(owner);
        resolver.clear(testName);

        // try with record
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_MANAGER,
                actor
            )
        );
        vm.prank(actor);
        resolver.clear(testName);
    }

    ////////////////////////////////////////////////////////////////////////
    // getRecordId() and getRecordCount()
    ////////////////////////////////////////////////////////////////////////

    function test_getRecordId() external {
        bytes32 node1 = NameCoder.namehash(testName, 0);
        bytes32 node2 = NameCoder.namehash(otherName, 0);

        assertEq(resolver.getRecordId(node1), 0, "unset");
        assertEq(resolver.getRecordId(node2), 0, "unset2");

        vm.prank(owner);
        resolver.setName(testName, "");
        assertEq(resolver.getRecordId(node1), 1, "new");

        vm.prank(owner);
        resolver.clear(testName);
        assertEq(resolver.getRecordId(node1), 2, "clear");

        vm.prank(owner);
        resolver.link(otherName, node1);
        assertEq(resolver.getRecordId(node2), 2, "link2");

        vm.prank(owner);
        resolver.link(otherName, bytes32(0));
        assertEq(resolver.getRecordId(node2), 0, "unlink2");
    }

    function test_getRecordCount() external {
        assertEq(resolver.getRecordCount(), 0, "empty");

        vm.prank(owner);
        resolver.setName(testName, "");
        assertEq(resolver.getRecordCount(), 1, "new");

        vm.prank(owner);
        resolver.clear(testName);
        assertEq(resolver.getRecordCount(), 2, "clear");

        vm.prank(owner);
        resolver.setName(otherName, "");
        assertEq(resolver.getRecordCount(), 3, "new2");

        vm.prank(owner);
        resolver.link(NameCoder.encode("alice.eth"), NameCoder.namehash(testName, 0));
        assertEq(resolver.getRecordCount(), 3, "link1");

        vm.prank(owner);
        resolver.link(NameCoder.encode("bob.eth"), NameCoder.namehash(otherName, 0));
        assertEq(resolver.getRecordCount(), 3, "link2");
    }

    ////////////////////////////////////////////////////////////////////////
    // EAC grant/revoke disabled
    ////////////////////////////////////////////////////////////////////////

    function test_grantRoles_disabled(uint256 resource, address account) external {
        vm.assume(resource > 0);
        uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                resource,
                roleBitmap,
                account
            )
        );
        resolver.grantRoles(resource, roleBitmap, account);
    }

    function test_revokeRoles_disabled(uint256 resource, address account) external {
        vm.assume(resource > 0);
        uint256 roleBitmap = EACBaseRolesLib.ALL_ROLES;
        vm.prank(owner);
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotRevokeRoles.selector,
                resource,
                roleBitmap,
                account
            )
        );
        resolver.revokeRoles(resource, roleBitmap, account);
    }

    ////////////////////////////////////////////////////////////////////////
    // authorizeRoles()
    ////////////////////////////////////////////////////////////////////////

    function test_authorizeRoles_anyName(uint8 roleBit) external {
        vm.assume(roleBit < 64);
        uint256 roleBitmap = 1 << (roleBit << 2);
        uint256 resource = PermissionedResolverLib.resource(0);

        vm.expectEmit();
        emit IEnhancedAccessControl.EACRolesChanged(resource, friend, 0, roleBitmap);
        vm.prank(owner);
        assertTrue(resolver.authorizeRoles(rootName, roleBitmap, friend, true), "grant");
        assertTrue(resolver.hasRoles(resource, roleBitmap, friend), "granted");

        vm.prank(owner);
        assertTrue(resolver.authorizeRoles(rootName, roleBitmap, friend, false), "revoke");
        assertFalse(resolver.hasRoles(resource, roleBitmap, friend), "revoked");
    }

    function test_authorizeRoles_sameAsGrantRevokeRootRoles(uint8 roleBit) external {
        vm.assume(roleBit < 64);
        uint256 roleBitmap = 1 << (roleBit << 2);

        vm.prank(owner);
        assertTrue(resolver.grantRootRoles(roleBitmap, friend), "grant");
        assertTrue(resolver.hasRoles(resolver.ROOT_RESOURCE(), roleBitmap, friend), "granted");

        vm.prank(owner);
        assertTrue(resolver.revokeRootRoles(roleBitmap, friend), "revoke");
        assertFalse(resolver.hasRoles(resolver.ROOT_RESOURCE(), roleBitmap, friend), "revoked");
    }

    function test_authorizeRoles_oneName(uint8 roleBit) external {
        vm.assume(roleBit < 64);
        uint256 roleBitmap = 1 << (roleBit << 2);
        uint256 recordId = 1;
        uint256 resource = PermissionedResolverLib.resource(recordId);

        vm.expectEmit();
        emit IPermissionedResolver.RecordResource(
            recordId,
            resource,
            PermissionedResolverLib.anySetter(testName)
        );
        vm.expectEmit();
        emit IEnhancedAccessControl.EACRolesChanged(resource, friend, 0, roleBitmap);
        vm.prank(owner);
        assertTrue(resolver.authorizeRoles(testName, roleBitmap, friend, true), "grant");
        assertTrue(resolver.hasRoles(resource, roleBitmap, friend), "granted");

        vm.prank(owner);
        assertTrue(resolver.authorizeRoles(testName, roleBitmap, friend, false), "revoke");
        assertFalse(resolver.hasRoles(resource, roleBitmap, friend), "revoked");
    }

    function test_authorizeRoles_notAuthorized(uint8 roleBit) external {
        vm.assume(roleBit < 64);
        uint256 roleBitmap = 1 << (roleBit << 2);

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACCannotGrantRoles.selector,
                PermissionedResolverLib.resource(1),
                roleBitmap,
                friend
            )
        );
        vm.prank(friend);
        resolver.authorizeRoles(testName, roleBitmap, owner, true);
    }

    function test_authorizeRoles_revokeInvalidRecord() external {
        vm.expectRevert(abi.encodeWithSelector(IPermissionedResolver.InvalidRecord.selector));
        vm.prank(owner);
        resolver.authorizeRoles(testName, EACBaseRolesLib.ALL_ROLES, friend, false);
    }

    ////////////////////////////////////////////////////////////////////////
    // decodeSetter()
    ////////////////////////////////////////////////////////////////////////

    function test_decodeSetter_setABI(uint8 contentTypeBit) external {
        vm.assume(contentTypeBit < 256);
        uint256 contentType = 1 << contentTypeBit;

        (bytes memory name, bytes32 part, uint256 roleBitmap, bytes memory setterPrefix) =
            resolver.decodeSetter(
                abi.encodeCall(PermissionedResolver.setABI, (testName, contentType, "<ignored>"))
            );
        assertEq(name, testName, "name");
        assertEq(part, PermissionedResolverLib.partHash(contentType), "part");
        assertEq(roleBitmap, PermissionedResolverLib.ROLE_SET_ABI, "role");
        assertEq(
            setterPrefix,
            abi.encodeWithSelector(PermissionedResolver.setABI.selector, testName, contentType)
        );
    }

    function test_decodeSetter_setAddress(uint256 coinType) external {
        (bytes memory name, bytes32 part, uint256 roleBitmap, bytes memory setterPrefix) =
            resolver.decodeSetter(
                abi.encodeCall(PermissionedResolver.setAddress, (testName, coinType, "<ignored>"))
            );
        assertEq(name, testName, "name");
        assertEq(part, PermissionedResolverLib.partHash(coinType), "part");
        assertEq(roleBitmap, PermissionedResolverLib.ROLE_SET_ADDRESS, "role");
        assertEq(
            setterPrefix,
            abi.encodeWithSelector(PermissionedResolver.setAddress.selector, testName, coinType)
        );
    }

    function test_decodeSetter_setData(string calldata key) external {
        (bytes memory name, bytes32 part, uint256 roleBitmap, bytes memory setterPrefix) =
            resolver.decodeSetter(
                abi.encodeCall(PermissionedResolver.setData, (testName, key, "<ignored>"))
            );
        assertEq(name, testName, "name");
        assertEq(part, PermissionedResolverLib.partHash(key), "part");
        assertEq(roleBitmap, PermissionedResolverLib.ROLE_SET_DATA, "role");
        assertEq(
            setterPrefix,
            abi.encodeWithSelector(PermissionedResolver.setData.selector, testName, key)
        );
    }

    function test_decodeSetter_setInterface(bytes4 interfaceId) external {
        (bytes memory name, bytes32 part, uint256 roleBitmap, bytes memory setterPrefix) =
            resolver.decodeSetter(
                abi.encodeCall(
                    PermissionedResolver.setInterface,
                    (testName, interfaceId, address(0))
                )
            );
        assertEq(name, testName, "name");
        assertEq(part, PermissionedResolverLib.partHash(interfaceId), "part");
        assertEq(roleBitmap, PermissionedResolverLib.ROLE_SET_INTERFACE, "role");
        assertEq(
            setterPrefix,
            abi.encodeWithSelector(PermissionedResolver.setInterface.selector, testName, interfaceId)
        );
    }

    function test_decodeSetter_setText(string calldata key) external {
        (bytes memory name, bytes32 part, uint256 roleBitmap, bytes memory setterPrefix) =
            resolver.decodeSetter(
                abi.encodeCall(PermissionedResolver.setText, (testName, key, "<ignored>"))
            );
        assertEq(name, testName, "name");
        assertEq(part, PermissionedResolverLib.partHash(key), "part");
        assertEq(roleBitmap, PermissionedResolverLib.ROLE_SET_TEXT, "role");
        assertEq(
            setterPrefix,
            abi.encodeWithSelector(PermissionedResolver.setText.selector, testName, key)
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // setABI()
    ////////////////////////////////////////////////////////////////////////

    function test_setABI(uint8 contentTypeBit, bytes calldata data) external {
        vm.assume(contentTypeBit < 256);
        uint256 contentType = 1 << contentTypeBit;

        vm.expectEmit();
        emit IABISetter.ABIUpdated(1, contentType);
        vm.prank(owner);
        resolver.setABI(testName, contentType, data);

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(IABIResolver.ABI, (bytes32(0), contentType))),
            data.length > 0 ? abi.encode(contentType, data) : abi.encode(0, "")
        );
    }

    function test_setABI_invalidContentType_noBits() external {
        uint256 contentType;
        vm.expectRevert(abi.encodeWithSelector(IABISetter.InvalidContentType.selector, contentType));
        vm.prank(owner);
        resolver.setABI(testName, contentType, "");
    }

    function test_setABI_invalidContentType_manyBits() external {
        uint256 contentType = 3;
        vm.expectRevert(abi.encodeWithSelector(IABISetter.InvalidContentType.selector, contentType));
        vm.prank(owner);
        resolver.setABI(testName, contentType, "");
    }

    function test_setABI_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_ABI,
                actor
            )
        );
        vm.prank(actor);
        resolver.setABI(testName, 1, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // setAddress()
    ////////////////////////////////////////////////////////////////////////

    function test_setAddress(uint256 coinType) external {
        bytes memory a =
            vm.randomBytes(ENSIP19.isEVMCoinType(coinType) ? 20 : vm.randomUint(1, 1000));

        assertFalse(_hasAddr(testName, coinType));

        vm.expectEmit();
        emit IAddressSetter.AddressUpdated(1, coinType, a);
        vm.prank(owner);
        resolver.setAddress(testName, coinType, a);

        assertTrue(_hasAddr(testName, coinType));

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(IAddressResolver.addr, (bytes32(0), coinType))),
            abi.encode(a)
        );
    }

    function test_setAddress_mainnet(address addr) external {
        vm.prank(owner);
        resolver.setAddress(testName, COIN_TYPE_ETH, abi.encodePacked(addr));

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(IAddrResolver.addr, (bytes32(0)))),
            abi.encode(addr)
        );
    }

    function test_setAddress_default(uint32 chain, address addr) external {
        vm.assume(chain > 0 && chain < COIN_TYPE_DEFAULT && addr != address(0));
        uint256 coinType = _coinTypeFromChain(chain);
        bytes memory a = abi.encodePacked(addr);

        // set default address
        vm.prank(owner);
        resolver.setAddress(testName, COIN_TYPE_DEFAULT, a);

        assertTrue(_hasAddr(testName, COIN_TYPE_DEFAULT), "set");
        assertFalse(_hasAddr(testName, coinType), "specific");

        // get specific address
        assertEq(
            _resolveWithUR(testName, abi.encodeCall(IAddressResolver.addr, (bytes32(0), coinType))),
            abi.encode(a)
        );
    }

    function test_setAddress_default_fallbacks() external {
        vm.startPrank(owner);
        resolver.setAddress(testName, COIN_TYPE_DEFAULT, abi.encodePacked(address(1)));
        resolver.setAddress(testName, COIN_TYPE_DEFAULT | 1, abi.encodePacked(address(0)));
        resolver.setAddress(testName, COIN_TYPE_DEFAULT | 2, abi.encodePacked(address(2)));
        vm.stopPrank();

        assertEq(
            _resolveWithUR(
                testName,
                abi.encodeCall(IAddressResolver.addr, (bytes32(0), COIN_TYPE_DEFAULT | 1))
            ),
            abi.encode(abi.encodePacked(address(0))),
            "block"
        );
        assertEq(
            _resolveWithUR(
                testName,
                abi.encodeCall(IAddressResolver.addr, (bytes32(0), COIN_TYPE_DEFAULT | 2))
            ),
            abi.encode(abi.encodePacked(address(2))),
            "override"
        );
        assertEq(
            _resolveWithUR(
                testName,
                abi.encodeCall(IAddressResolver.addr, (bytes32(0), COIN_TYPE_DEFAULT | 3))
            ),
            abi.encode(abi.encodePacked(address(1))),
            "fallback"
        );
    }

    function test_setAddress_zeroEVM() external {
        assertFalse(_hasAddr(testName, COIN_TYPE_ETH), "unset");

        vm.prank(owner);
        resolver.setAddress(testName, COIN_TYPE_ETH, abi.encodePacked(address(0)));

        assertTrue(_hasAddr(testName, COIN_TYPE_ETH), "set");

        vm.prank(owner);
        resolver.setAddress(testName, COIN_TYPE_ETH, "");

        assertFalse(_hasAddr(testName, COIN_TYPE_ETH), "clear");
    }

    function test_setAddress_invalidEVMAddress(uint32 chain, bytes calldata a) external {
        vm.assume(chain > 0 && chain < COIN_TYPE_DEFAULT && a.length != 0 && a.length != 20);
        uint256 coinType = _coinTypeFromChain(chain);

        vm.expectRevert(abi.encodeWithSelector(IAddressSetter.InvalidEVMAddress.selector, a));
        resolver.setAddress(testName, coinType, a);
    }

    function test_setAddress_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_ADDRESS,
                actor
            )
        );
        vm.prank(actor);
        resolver.setAddress(testName, COIN_TYPE_ETH, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // setContentHash()
    ////////////////////////////////////////////////////////////////////////

    function test_setContentHash(bytes calldata contentHash) external {
        vm.expectEmit();
        emit IContentHashSetter.ContentHashUpdated(1, contentHash);
        vm.prank(owner);
        resolver.setContentHash(testName, contentHash);

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(IContentHashResolver.contenthash, (bytes32(0)))),
            abi.encode(contentHash)
        );
    }

    function test_setContentHash_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_CONTENTHASH,
                actor
            )
        );
        vm.prank(actor);
        resolver.setContentHash(testName, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // setData()
    ////////////////////////////////////////////////////////////////////////

    function test_setData(string calldata key, bytes calldata value) external {
        vm.expectEmit();
        emit IDataSetter.DataUpdated(1, key, key, value);
        vm.prank(owner);
        resolver.setData(testName, key, value);

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(IDataResolver.data, (bytes32(0), key))),
            abi.encode(value)
        );
    }

    function test_setData_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_DATA,
                actor
            )
        );
        vm.prank(actor);
        resolver.setData(testName, "", "");
    }

    ////////////////////////////////////////////////////////////////////////
    // setInterface()
    ////////////////////////////////////////////////////////////////////////

    function test_setInterface(bytes4 interfaceId, address implementer) external {
        vm.assume(!resolver.supportsInterface(interfaceId));

        vm.expectEmit();
        emit IInterfaceSetter.InterfaceUpdated(1, interfaceId, implementer);
        vm.prank(owner);
        resolver.setInterface(testName, interfaceId, implementer);

        assertEq(
            _resolveWithUR(
                testName,
                abi.encodeCall(IInterfaceResolver.interfaceImplementer, (bytes32(0), interfaceId))
            ),
            abi.encode(implementer)
        );
    }

    function test_interfaceImplementer_withPointer() external {
        MockInterface c = new MockInterface();
        assertTrue(ERC165Checker.supportsInterface(address(c), TEST_SELECTOR));

        vm.prank(owner);
        resolver.setAddress(testName, COIN_TYPE_ETH, abi.encodePacked(c));

        assertEq(
            _resolveWithUR(
                testName,
                abi.encodeCall(IInterfaceResolver.interfaceImplementer, (bytes32(0), TEST_SELECTOR))
            ),
            abi.encode(c)
        );
    }

    function test_setInterface_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_INTERFACE,
                actor
            )
        );
        vm.prank(actor);
        resolver.setInterface(testName, bytes4(0), address(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // setName()
    ////////////////////////////////////////////////////////////////////////

    function test_setName(string calldata name) external {
        vm.expectEmit();
        emit INameSetter.NameUpdated(1, name);
        vm.prank(owner);
        resolver.setName(testName, name);

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(INameResolver.name, (bytes32(0)))),
            abi.encode(name)
        );
    }

    function test_setName_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_NAME,
                actor
            )
        );
        vm.prank(actor);
        resolver.setName(testName, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // setPubkey()
    ////////////////////////////////////////////////////////////////////////

    function test_setPubkey(bytes32 x, bytes32 y) external {
        vm.expectEmit();
        emit IPubkeySetter.PubkeyUpdated(1, x, y);
        vm.prank(owner);
        resolver.setPubkey(testName, x, y);

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(IPubkeyResolver.pubkey, (bytes32(0)))),
            abi.encode(x, y)
        );
    }

    function test_setPubkey_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_PUBKEY,
                actor
            )
        );
        vm.prank(actor);
        resolver.setPubkey(testName, 0, 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // setText()
    ////////////////////////////////////////////////////////////////////////

    function test_setText(string calldata key, string calldata value) external {
        vm.expectEmit();
        emit ITextSetter.TextUpdated(1, key, key, value);
        vm.prank(owner);
        resolver.setText(testName, key, value);

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(ITextResolver.text, (bytes32(0), key))),
            abi.encode(value)
        );
    }

    function test_setText_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                actor
            )
        );
        vm.prank(actor);
        resolver.setText(testName, "", "");
    }

    function test_setText_anyName_anyPart(string calldata key) external {
        // friend cannot change testName
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(testName, key, "A");

        // give friend setText(*) on any record
        vm.prank(owner);
        resolver.authorizeRoles(rootName, PermissionedResolverLib.ROLE_SET_TEXT, friend, true);

        // friend can change same setter of testName
        vm.prank(friend);
        resolver.setText(testName, key, "B");

        // friend can change same setter of otherName
        vm.prank(friend);
        resolver.setText(otherName, key, "C");

        // friend can change diff setter of otherName
        vm.prank(friend);
        resolver.setText(otherName, string.concat(key, "2"), "D");
    }

    function test_setText_oneName_anyPart(string calldata key) external {
        // friend cannot change testName
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(testName, key, "A");

        // give friend setText(*) on testName
        vm.prank(owner);
        resolver.authorizeRoles(testName, PermissionedResolverLib.ROLE_SET_TEXT, friend, true);

        // friend can change diff setter of testName
        vm.prank(friend);
        resolver.setText(testName, string.concat(key, "2"), "B");

        // friend cannot change same setter of otherName
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(2),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(otherName, key, "C");
    }

    function test_setText_anyName_onePart(string calldata key) external {
        // friend cannot change testName
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(testName, key, "A");

        // give friend setText(key) on any record
        vm.prank(owner);
        resolver.authorizeSubroles(
            abi.encodeCall(PermissionedResolver.setText, (rootName, key, "<ignored>")),
            friend,
            true
        );

        // friend can change same setter of testName
        vm.prank(friend);
        resolver.setText(testName, key, "B");

        // friend can change same setter of otherName
        vm.prank(friend);
        resolver.setText(otherName, key, "C");

        // friend cannot change diff setter of testName
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(testName, string.concat(key, "2"), "D");
    }

    function test_setText_oneName_onePart(string calldata key) external {
        // friend cannot change testName
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(testName, key, "A");

        // give friend setText(key) on testName
        vm.prank(owner);
        resolver.authorizeSubroles(
            abi.encodeCall(PermissionedResolver.setText, (testName, key, "<ignored>")),
            friend,
            true
        );

        // friend can change same setter of testName
        vm.prank(friend);
        resolver.setText(testName, key, "B");

        // friend cannot change diff setter of testName
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(testName, string.concat(key, "2"), "D");

        // friend cannot change same setter of otherName
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(2),
                PermissionedResolverLib.ROLE_SET_TEXT,
                friend
            )
        );
        vm.prank(friend);
        resolver.setText(otherName, key, "E");
    }

    ////////////////////////////////////////////////////////////////////////
    // multicall()
    ////////////////////////////////////////////////////////////////////////

    function test_multicall_setters(bool checked, string calldata name, bytes calldata contentHash)
        external
    {
        bytes[] memory calls = new bytes[](2);
        calls[0] = abi.encodeCall(PermissionedResolver.setName, (testName, name));
        calls[1] = abi.encodeCall(PermissionedResolver.setContentHash, (testName, contentHash));

        vm.prank(owner);
        if (checked) {
            resolver.multicallWithNodeCheck(keccak256("ignored"), calls);
        } else {
            resolver.multicall(calls);
        }

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(INameResolver.name, bytes32(0))),
            abi.encode(name),
            "name"
        );
        assertEq(
            _resolveWithUR(testName, abi.encodeCall(IContentHashResolver.contenthash, bytes32(0))),
            abi.encode(contentHash),
            "contenthash"
        );
    }

    function test_multicall_setters_notAuthorized() external {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(PermissionedResolver.setName, (testName, ""));

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(1),
                PermissionedResolverLib.ROLE_SET_NAME,
                address(this)
            )
        );
        resolver.multicall(calls);
    }

    function test_multicall_getters() external {
        vm.startPrank(owner);
        resolver.setAddress(testName, COIN_TYPE_DEFAULT, testAddress);
        resolver.setContentHash(testName, TEST_BYTES);
        resolver.setData(testName, "DATA_KEY", TEST_BYTES);
        resolver.setName(testName, "NAME");
        resolver.setText(testName, "TEXT_KEY", "TEXT_VALUE");
        vm.stopPrank();

        bytes[] memory calls = new bytes[](6);
        calls[0] = abi.encodeCall(IAddrResolver.addr, (bytes32(0)));
        calls[1] = abi.encodeCall(IAddressResolver.addr, (bytes32(0), COIN_TYPE_ETH));
        calls[2] = abi.encodeCall(IContentHashResolver.contenthash, (bytes32(0)));
        calls[3] = abi.encodeCall(IDataResolver.data, (bytes32(0), "DATA_KEY"));
        calls[4] = abi.encodeCall(INameResolver.name, (bytes32(0)));
        calls[5] = abi.encodeCall(ITextResolver.text, (bytes32(0), "TEXT_KEY"));

        bytes[] memory answers = new bytes[](calls.length);
        answers[0] = abi.encode(testAddr);
        answers[1] = abi.encode(testAddress);
        answers[2] = abi.encode(TEST_BYTES);
        answers[3] = abi.encode(TEST_BYTES);
        answers[4] = abi.encode("NAME");
        answers[5] = abi.encode("TEXT_VALUE");

        assertEq(
            _resolveWithUR(testName, abi.encodeCall(IMulticallable.multicall, (calls))),
            abi.encode(answers)
        );
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

    function test_default_setABI(uint8 contentTypeBit, bytes calldata data) external {
        vm.assume(contentTypeBit < 256);
        uint256 contentType = 1 << contentTypeBit;

        vm.prank(owner);
        resolver.setABI(rootName, contentType, data);

        assertEq(
            resolver.resolve(dneName, abi.encodeCall(IABIResolver.ABI, (bytes32(0), contentType))),
            data.length > 0 ? abi.encode(contentType, data) : abi.encode(0, "")
        );
    }

    function test_default_setAddress(uint256 coinType) external {
        bytes memory a =
            vm.randomBytes(ENSIP19.isEVMCoinType(coinType) ? 20 : vm.randomUint(1, 1000));

        vm.prank(owner);
        resolver.setAddress(rootName, coinType, a);

        assertEq(
            resolver.resolve(dneName, abi.encodeCall(IAddressResolver.addr, (bytes32(0), coinType))),
            abi.encode(a)
        );
    }

    function test_default_setContentHash(bytes calldata contentHash) external {
        vm.prank(owner);
        resolver.setContentHash(rootName, contentHash);

        assertEq(
            resolver.resolve(dneName, abi.encodeCall(IContentHashResolver.contenthash, (bytes32(0)))),
            abi.encode(contentHash)
        );
    }

    function test_default_setData(string calldata key, bytes calldata value) external {
        vm.prank(owner);
        resolver.setData(rootName, key, value);

        assertEq(
            resolver.resolve(dneName, abi.encodeCall(IDataResolver.data, (bytes32(0), key))),
            abi.encode(value)
        );
    }

    function test_default_setInterface(bytes4 interfaceId, address implementer) external {
        vm.prank(owner);
        resolver.setInterface(rootName, interfaceId, implementer);

        assertEq(
            resolver.resolve(
                dneName,
                abi.encodeCall(IInterfaceResolver.interfaceImplementer, (bytes32(0), interfaceId))
            ),
            abi.encode(implementer)
        );
    }

    function test_default_setName(string calldata name) external {
        vm.prank(owner);
        resolver.setName(rootName, name);

        assertEq(
            resolver.resolve(dneName, abi.encodeCall(INameResolver.name, (bytes32(0)))),
            abi.encode(name)
        );
    }

    function test_default_setPubkey(bytes32 x, bytes32 y) external {
        vm.prank(owner);
        resolver.setPubkey(rootName, x, y);

        assertEq(
            resolver.resolve(dneName, abi.encodeCall(IPubkeyResolver.pubkey, (bytes32(0)))),
            abi.encode(x, y)
        );
    }

    function test_default_setText(string calldata key, string calldata value) external {
        vm.prank(owner);
        resolver.setText(rootName, key, value);

        assertEq(
            resolver.resolve(dneName, abi.encodeCall(ITextResolver.text, (bytes32(0), key))),
            abi.encode(value)
        );
    }

    /*
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
        resolver.authorizeTextRoles(NameCoder.encode(""), testString, friend, true);

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
        resolver.authorizeTextRoles(testName, testString, friend, true);

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

    function test_setData_anyNode_onePart() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_DATA,
                friend
            )
        );
        vm.prank(friend);
        resolver.setData(testNode, testString, "A");

        vm.prank(owner);
        resolver.authorizeDataRoles(NameCoder.encode(""), testString, friend, true);

        vm.prank(friend);
        resolver.setData(testNode, testString, "B");

        vm.prank(friend);
        resolver.setData(~testNode, testString, "C");

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_DATA,
                friend
            )
        );
        vm.prank(friend);
        resolver.setData(testNode, string.concat(testString, testString), "D");
    }

    function test_setData_oneNode_onePart() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(testNode, 0),
                PermissionedResolverLib.ROLE_SET_DATA,
                friend
            )
        );
        vm.prank(friend);
        resolver.setData(testNode, testString, "A");

        vm.prank(owner);
        resolver.authorizeDataRoles(testName, testString, friend, true);

        vm.prank(friend);
        resolver.setData(testNode, testString, "B");

        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                PermissionedResolverLib.resource(~testNode, 0),
                PermissionedResolverLib.ROLE_SET_DATA,
                friend
            )
        );
        vm.prank(friend);
        resolver.setData(~testNode, testString, "C");
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
        resolver.authorizeAddrRoles(NameCoder.encode(""), coinType, friend, true);

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
        resolver.authorizeAddrRoles(testName, coinType, friend, true);

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
    */

    ////////////////////////////////////////////////////////////////////////
    // IContractNamer
    ////////////////////////////////////////////////////////////////////////

    function test_implementationIsNameable() external view {
        assertTrue(implementation.isContractNamer(address(this)));
    }

    function test_isContractNamer() external {
        assertTrue(resolver.isContractNamer(owner), "owner");
        assertFalse(resolver.isContractNamer(friend), "before");

        vm.prank(owner);
        resolver.grantRootRoles(PermissionedResolverLib.ROLE_CAN_NAME, friend);
        assertTrue(resolver.isContractNamer(friend), "granted");

        vm.prank(owner);
        resolver.revokeRootRoles(PermissionedResolverLib.ROLE_CAN_NAME, friend);
        assertFalse(resolver.isContractNamer(friend), "revoked");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _coinTypeFromChain(uint32 chain) internal pure returns (uint256) {
        return chain == CHAIN_ID_ETH ? COIN_TYPE_ETH : (COIN_TYPE_DEFAULT | chain);
    }

    function _resolveWithUR(bytes memory name, bytes memory data)
        public
        view
        returns (bytes memory result)
    {
        address resolver_;
        (result, resolver_) = universalResolver.resolve(name, data);
        assertEq(resolver_, address(resolver), "resolver");
    }

    function _hasAddr(bytes memory name, uint256 coinType) internal view returns (bool) {
        return
            abi.decode(
                _resolveWithUR(
                    name,
                    abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), coinType))
                ),
                (bool)
            );
    }
}


contract MockUpgrade is IExtendedResolver, UUPSUpgradeable, IProxyAuthorization {
    function resolve(bytes calldata, bytes calldata) external pure returns (bytes memory) {
        return abi.encode(address(0x12345));
    }
    function canUpgradeFrom(address) external pure returns (bool) {
        return true;
    }
    function _authorizeUpgrade(address) internal override {}
}


contract MockInterface is ERC165 {
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == TEST_SELECTOR || super.supportsInterface(interfaceId);
    }
}
