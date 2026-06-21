// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IMulticallable} from "@ens/contracts/resolvers/IMulticallable.sol";

//import {IABIResolver} from "@ens/contracts/resolvers/profiles/IABIResolver.sol";
import {IAddressResolver} from "@ens/contracts/resolvers/profiles/IAddressResolver.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IContentHashResolver} from "@ens/contracts/resolvers/profiles/IContentHashResolver.sol";
import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {IDataResolver} from "@ens/contracts/resolvers/profiles/IDataResolver.sol";
import {IHasAddressResolver} from "@ens/contracts/resolvers/profiles/IHasAddressResolver.sol";
import {IInterfaceResolver} from "@ens/contracts/resolvers/profiles/IInterfaceResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {IPubkeyResolver} from "@ens/contracts/resolvers/profiles/IPubkeyResolver.sol";
import {ITextResolver} from "@ens/contracts/resolvers/profiles/ITextResolver.sol";
import {ResolverFeatures} from "@ens/contracts/resolvers/ResolverFeatures.sol";
import {
    ENSIP19,
    COIN_TYPE_ETH,
    COIN_TYPE_DEFAULT,
    CHAIN_ID_ETH
} from "@ens/contracts/utils/ENSIP19.sol";
import {IERC7996} from "@ens/contracts/utils/IERC7996.sol";

import {IAddressSetter} from "~src/resolver/interfaces/setters/IAddressSetter.sol";
import {IContentHashSetter} from "~src/resolver/interfaces/setters/IContentHashSetter.sol";
import {IDataSetter} from "~src/resolver/interfaces/setters/IDataSetter.sol";
import {IInterfaceSetter} from "~src/resolver/interfaces/setters/IInterfaceSetter.sol";
import {INameSetter} from "~src/resolver/interfaces/setters/INameSetter.sol";
import {IPubkeySetter} from "~src/resolver/interfaces/setters/IPubkeySetter.sol";
import {ITextSetter} from "~src/resolver/interfaces/setters/ITextSetter.sol";
import {SharedResolver} from "~src/resolver/SharedResolver.sol";
import {IContractNamer} from "~src/reverse-registrar/interfaces/IContractNamer.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

bytes4 constant TEST_SELECTOR = 0x12345678;

contract SharedResolverTest is V2Fixture {
    SharedResolver resolver;

    address actor = makeAddr("actor");
    address friend = makeAddr("friend");

    bytes nullName;
    bytes unregName;
    bytes testName;
    bytes32 testNode;
    bytes otherName;

    function setUp() external {
        deployV2Fixture();
        resolver = new SharedResolver(rootRegistry, contractNamer);

        nullName = NameCoder.encode("");
        unregName = NameCoder.encode("unreg");
        testName = _register("test");
        testNode = NameCoder.namehash(testName, 0);
        otherName = _register("other");
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IContractNamer).interfaceId),
            "IContractNamer"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IExtendedResolver).interfaceId),
            "IExtendedResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IERC7996).interfaceId),
            "IERC7996"
        );
        assertTrue(
            ERC165Checker.supportsInterface(address(resolver), type(IMulticallable).interfaceId),
            "IMulticallable"
        );

        // setters
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
            ERC165Checker.supportsInterface(address(resolver), type(ITextSetter).interfaceId),
            "ITextSetter"
        );
    }

    function test_supportsFeature() external view {
        assertTrue(resolver.supportsFeature(ResolverFeatures.RESOLVE_MULTICALL), "RESOLVE_MULTICALL");
    }

    function test_ownerOf() external {
        assertEq(resolver.ownerOf(nullName), address(0), "null");
        assertEq(resolver.ownerOf(unregName), address(0), "unreg");
        assertEq(resolver.ownerOf(testName), address(this), "test");
        assertEq(resolver.ownerOf(otherName), address(this), "other");
    }

    function test_canModifyName_null() external {
        assertFalse(resolver.canModifyName(nullName, address(0)), "null");
        assertFalse(resolver.canModifyName(nullName, address(this)), "this");
        assertFalse(resolver.canModifyName(nullName, address(actor)), "actor");
    }

    function test_canModifyName_unregistered() external {
        assertFalse(resolver.canModifyName(unregName, address(0)), "null");
        assertFalse(resolver.canModifyName(unregName, address(this)), "this");
        assertFalse(resolver.canModifyName(unregName, address(actor)), "actor");
    }

    function test_canModifyName_registered() external {
        assertFalse(resolver.canModifyName(testName, address(0)), "null");
        assertTrue(resolver.canModifyName(testName, address(this)), "this");
        assertFalse(resolver.canModifyName(testName, address(actor)), "actor");
    }

    function test_approve_name() external {
        assertFalse(resolver.isApproved(testName, address(this), friend), "before:approved");
        assertFalse(resolver.canModifyName(testName, address(friend)), "before:modify");

        vm.expectEmit();
        emit SharedResolver.ApprovalUpdated(testNode, testName, address(this), friend, true);
        resolver.approve(testName, friend, true);

        assertTrue(resolver.isApproved(testName, address(this), friend), "approved:testName");
        assertTrue(resolver.canModifyName(testName, address(friend)), "modify:friend");
        assertFalse(resolver.canModifyName(testName, address(actor)), "modify:actor");

        vm.expectEmit();
        emit SharedResolver.ApprovalUpdated(testNode, testName, address(this), friend, false);
        resolver.approve(testName, friend, false);

        assertFalse(resolver.isApproved(testName, address(this), friend), "revoked:approved");
        assertFalse(resolver.canModifyName(testName, address(friend)), "revoked:modify");
    }

    function test_approve_any() external {
        assertFalse(resolver.isApproved(nullName, address(this), friend), "before:null");
        assertFalse(resolver.isApproved(testName, address(this), friend), "before:approved");
        assertFalse(resolver.canModifyName(testName, address(friend)), "before:modify");

        vm.expectEmit();
        emit SharedResolver.ApprovalUpdated(bytes32(0), nullName, address(this), friend, true);
        resolver.approve(nullName, friend, true);

        assertTrue(resolver.isApproved(nullName, address(this), friend), "approved:null");
        assertFalse(resolver.canModifyName(nullName, address(this)), "modify:null");

        assertFalse(resolver.isApproved(testName, address(this), friend), "approved:test");
        assertTrue(resolver.canModifyName(testName, address(friend)), "modify:friend");
        assertFalse(resolver.canModifyName(testName, address(actor)), "modify:actor");

        assertTrue(resolver.canModifyName(otherName, address(friend)), "modify:other");

        vm.expectEmit();
        emit SharedResolver.ApprovalUpdated(bytes32(0), nullName, address(this), friend, false);
        resolver.approve(nullName, friend, false);

        assertFalse(resolver.isApproved(nullName, address(this), friend), "revoked:null");
        assertFalse(resolver.isApproved(testName, address(this), friend), "revoked:approved");
        assertFalse(resolver.canModifyName(testName, address(friend)), "revoked:modify");
        assertFalse(resolver.canModifyName(otherName, address(friend)), "revoked:other");
    }

    ////////////////////////////////////////////////////////////////////////
    // resolve()
    ////////////////////////////////////////////////////////////////////////

    function test_resolve_unsupported() external {
        vm.expectRevert(
            abi.encodeWithSelector(SharedResolver.UnsupportedResolverProfile.selector, TEST_SELECTOR)
        );
        resolver.resolve(testName, abi.encodeWithSelector(TEST_SELECTOR));
    }

    function test_resolve_noCalldata() external {
        vm.expectRevert(
            abi.encodeWithSelector(SharedResolver.UnsupportedResolverProfile.selector, bytes4(0))
        );
        resolver.resolve(testName, "");
    }

    function test_resolve_emptyMulticall() external {
        assertEq(
            resolver.resolve(testName, abi.encodeCall(IMulticallable.multicall, (new bytes[](0)))),
            abi.encode(new bytes[](0))
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // setAddress()
    ////////////////////////////////////////////////////////////////////////

    function test_setAddress(uint256 coinType) external {
        bytes memory a =
            vm.randomBytes(ENSIP19.isEVMCoinType(coinType) ? 20 : vm.randomUint(1, 1000));

        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), coinType))
            ),
            abi.encode(false),
            "before"
        );

        vm.expectEmit();
        emit IAddressSetter.AddressUpdated(testNode, testName, coinType, a);
        resolver.setAddress(testName, coinType, a);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddressResolver.addr, (bytes32(0), coinType))),
            abi.encode(a),
            "resolve"
        );

        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), coinType))
            ),
            abi.encode(true),
            "after"
        );
    }

    function test_setAddress_mainnet(address addr) external {
        resolver.setAddress(testName, COIN_TYPE_ETH, abi.encodePacked(addr));

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddrResolver.addr, (bytes32(0)))),
            abi.encode(addr)
        );
    }

    function test_setAddress_zeroEVM() external {
        uint256 coinType = COIN_TYPE_ETH;

        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), coinType))
            ),
            abi.encode(false),
            "before"
        );

        resolver.setAddress(testName, coinType, abi.encodePacked(address(0)));

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddrResolver.addr, (bytes32(0)))),
            abi.encode(address(0)),
            "resolve"
        );

        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), coinType))
            ),
            abi.encode(true),
            "after"
        );
    }

    function test_setAddress_default(uint32 chain, address addr) external {
        vm.assume(chain > 0 && chain < COIN_TYPE_DEFAULT && addr != address(0));
        uint256 coinType = _coinTypeFromChain(chain);
        bytes memory a = abi.encodePacked(addr);

        resolver.setAddress(testName, COIN_TYPE_DEFAULT, a);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddressResolver.addr, (bytes32(0), coinType))),
            abi.encode(a),
            "addr(*)"
        );
        assertEq(
            resolver.resolve(testName, abi.encodeCall(IAddrResolver.addr, (bytes32(0)))),
            abi.encode(addr),
            "addr()"
        );

        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), coinType))
            ),
            abi.encode(false),
            "hasAddr(*)"
        );
        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), COIN_TYPE_DEFAULT))
            ),
            abi.encode(true),
            "hasAddr(default)"
        );
    }

    function test_setAddress_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(SharedResolver.CannotModifyName.selector, testName));
        vm.prank(actor);
        resolver.setAddress(testName, 0, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // setContentHash()
    ////////////////////////////////////////////////////////////////////////

    function test_setContentHash(bytes calldata contentHash) external {
        vm.expectEmit();
        emit IContentHashSetter.ContentHashUpdated(testNode, testName, contentHash);
        resolver.setContentHash(testName, contentHash);
    }

    function test_setContentHash_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(SharedResolver.CannotModifyName.selector, testName));
        vm.prank(actor);
        resolver.setContentHash(testName, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // setData()
    ////////////////////////////////////////////////////////////////////////

    function test_setData(string calldata key, bytes calldata value) external {
        vm.expectEmit();
        emit IDataSetter.DataUpdated(testNode, testName, key, key, value);
        resolver.setData(testName, key, value);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IDataResolver.data, (bytes32(0), key))),
            abi.encode(value)
        );
    }

    function test_setData_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(SharedResolver.CannotModifyName.selector, testName));
        vm.prank(actor);
        resolver.setData(testName, "", "");
    }

    ////////////////////////////////////////////////////////////////////////
    // setInterface()
    ////////////////////////////////////////////////////////////////////////

    function test_setInterface(bytes4 interfaceId, address impl) external {
        vm.expectEmit();
        emit IInterfaceSetter.InterfaceUpdated(testNode, testName, interfaceId, impl);
        resolver.setInterface(testName, interfaceId, impl);

        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IInterfaceResolver.interfaceImplementer, (bytes32(0), interfaceId))
            ),
            abi.encode(impl)
        );
    }

    function test_setInterface_viaAddr() external {
        MockInterface c = new MockInterface();
        assertTrue(c.supportsInterface(TEST_SELECTOR));

        resolver.setAddress(testName, COIN_TYPE_ETH, abi.encodePacked(c));

        assertEq(
            resolver.resolve(
                testName,
                abi.encodeCall(IInterfaceResolver.interfaceImplementer, (bytes32(0), TEST_SELECTOR))
            ),
            abi.encode(c)
        );
    }

    function test_setInterface_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(SharedResolver.CannotModifyName.selector, testName));
        vm.prank(actor);
        resolver.setInterface(testName, bytes4(0), address(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // setName()
    ////////////////////////////////////////////////////////////////////////

    function test_setName(string calldata primaryName) external {
        vm.expectEmit();
        emit INameSetter.NameUpdated(testNode, testName, primaryName);
        resolver.setName(testName, primaryName);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(INameResolver.name, (bytes32(0)))),
            abi.encode(primaryName)
        );
    }

    function test_setName_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(SharedResolver.CannotModifyName.selector, testName));
        vm.prank(actor);
        resolver.setName(testName, "");
    }

    ////////////////////////////////////////////////////////////////////////
    // setPubkey()
    ////////////////////////////////////////////////////////////////////////

    function test_setPubkey(bytes32 x, bytes32 y) external {
        vm.expectEmit();
        emit IPubkeySetter.PubkeyUpdated(testNode, testName, x, y);
        resolver.setPubkey(testName, x, y);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IPubkeyResolver.pubkey, (bytes32(0)))),
            abi.encode(x, y)
        );
    }

    function test_setPubkey_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(SharedResolver.CannotModifyName.selector, testName));
        vm.prank(actor);
        resolver.setPubkey(testName, bytes32(0), bytes32(0));
    }

    ////////////////////////////////////////////////////////////////////////
    // setText()
    ////////////////////////////////////////////////////////////////////////

    function test_setText(string calldata key, string calldata value) external {
        vm.expectEmit();
        emit ITextSetter.TextUpdated(testNode, testName, key, key, value);
        resolver.setText(testName, key, value);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(ITextResolver.text, (bytes32(0), key))),
            abi.encode(value)
        );
    }

    function test_setText_notAuthorized() external {
        vm.expectRevert(abi.encodeWithSelector(SharedResolver.CannotModifyName.selector, testName));
        vm.prank(actor);
        resolver.setText(testName, "", "");
    }

    ////////////////////////////////////////////////////////////////////////
    // resolve() and multicall()
    ////////////////////////////////////////////////////////////////////////

    function test_multicall(bool checked) external {
        string memory s = "abc";
        address addr = address(0x1111);
        bytes memory v = abi.encodePacked(addr);

        bytes[] memory m = new bytes[](6);
        m[0] = abi.encodeCall(IAddressSetter.setAddress, (testName, COIN_TYPE_DEFAULT, v));
        m[1] = abi.encodeCall(IContentHashSetter.setContentHash, (testName, v));
        m[2] = abi.encodeCall(IDataSetter.setData, (testName, s, v));
        m[3] = abi.encodeCall(IInterfaceSetter.setInterface, (testName, TEST_SELECTOR, addr));
        m[4] = abi.encodeCall(INameSetter.setName, (testName, s));
        m[5] = abi.encodeCall(ITextSetter.setText, (testName, s, s));

        if (checked) {
            resolver.multicallWithNodeCheck(keccak256("dne"), m);
        } else {
            resolver.multicall(m);
        }

        bytes[] memory calls = new bytes[](m.length + 3);
        calls[0] = abi.encodeCall(IAddressResolver.addr, (bytes32(0), COIN_TYPE_DEFAULT));
        calls[1] = abi.encodeCall(IContentHashResolver.contenthash, (bytes32(0)));
        calls[2] = abi.encodeCall(IDataResolver.data, (bytes32(0), s));
        calls[3] = abi.encodeCall(
            IInterfaceResolver.interfaceImplementer,
            (bytes32(0), TEST_SELECTOR)
        );
        calls[4] = abi.encodeCall(INameResolver.name, (bytes32(0)));
        calls[5] = abi.encodeCall(ITextResolver.text, (bytes32(0), s));
        //
        calls[6] = abi.encodeCall(IAddrResolver.addr, (bytes32(0)));
        calls[7] = abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), COIN_TYPE_DEFAULT));
        calls[8] = abi.encodeCall(IHasAddressResolver.hasAddr, (bytes32(0), 0));

        bytes[] memory results = new bytes[](calls.length);
        results[0] = abi.encode(v);
        results[1] = abi.encode(v);
        results[2] = abi.encode(v);
        results[3] = abi.encode(addr);
        results[4] = abi.encode(s);
        results[5] = abi.encode(s);
        //
        results[6] = abi.encode(addr);
        results[7] = abi.encode(true);
        results[8] = abi.encode(false);

        assertEq(
            resolver.resolve(testName, abi.encodeCall(IMulticallable.multicall, (calls))),
            abi.encode(results)
        );
    }

    function test_multicall_oneError_notAuthorized() external {
        bytes[] memory m = new bytes[](2);
        m[0] = abi.encodeCall(INameSetter.setName, (testName, ""));
        m[1] = abi.encodeCall(INameSetter.setName, (unregName, "")); // wrong

        vm.expectRevert(abi.encodeWithSelector(SharedResolver.CannotModifyName.selector, unregName));
        resolver.multicall(m);
    }

    function test_multicall_oneError_unknown() external {
        bytes[] memory m = new bytes[](2);
        m[0] = abi.encodeCall(INameSetter.setName, (testName, ""));
        m[1] = abi.encodeWithSelector(TEST_SELECTOR); // wrong

        vm.expectRevert();
        resolver.multicall(m);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    function _coinTypeFromChain(uint32 chain) internal pure returns (uint256) {
        return chain == CHAIN_ID_ETH ? COIN_TYPE_ETH : (COIN_TYPE_DEFAULT | chain);
    }

    function _register(string memory label) internal returns (bytes memory) {
        ethRegistry.register(
            label,
            address(this),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        return NameCoder.ethName(label);
    }
}


contract MockInterface is ERC165 {
    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == TEST_SELECTOR || super.supportsInterface(interfaceId);
    }
}
