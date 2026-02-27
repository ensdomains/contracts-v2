// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {Test} from "forge-std/Test.sol";

import {VerifiableFactory} from "@ensdomains/verifiable-factory/VerifiableFactory.sol";

import {IEnhancedAccessControl} from "~src/access-control/interfaces/IEnhancedAccessControl.sol";
import {EACBaseRolesLib} from "~src/access-control/libraries/EACBaseRolesLib.sol";
import {
    AuthorizedResolver,
    AuthorizedResolverLib,
    IResolverAuthority,
    IAddressResolver,
    IAddrResolver,
    IHasAddressResolver,
    ENSIP19,
    NameCoder,
    COIN_TYPE_ETH,
    COIN_TYPE_DEFAULT
} from "~src/resolver/AuthorizedResolver.sol";
import {MockHCAFactoryBasic} from "~test/mocks/MockHCAFactoryBasic.sol";

contract AuthorizedResolverTest is Test {
    VerifiableFactory factory;
    AuthorizedResolver impl;
    AuthorizedResolver OR;
    MockAuthority authority;
    AuthorizedResolver AR;

    address user = makeAddr("user");
    address friend = makeAddr("friend");

    string testLabel = "test";
    address testAddr = makeAddr("test");
    bytes testAddress = abi.encodePacked(testAddr);
    bytes testBytes = hex"123456";

    function setUp() external {
        factory = new VerifiableFactory();
        impl = new AuthorizedResolver(new MockHCAFactoryBasic());
        {
            bytes memory v = abi.encodeCall(
                AuthorizedResolver.initialize,
                (address(this), EACBaseRolesLib.ALL_ROLES)
            );
            OR = AuthorizedResolver(factory.deployProxy(address(impl), uint256(keccak256(v)), v));
        }
        authority = new MockAuthority();
        {
            bytes memory v = abi.encodeCall(AuthorizedResolver.initialize, (address(authority), 0));
            AR = AuthorizedResolver(factory.deployProxy(address(impl), uint256(keccak256(v)), v));
        }
    }

    function test_constructor() external view {
        assertTrue(OR.hasRoles(0, EACBaseRolesLib.ALL_ROLES, address(this)), "roles");
        assertEq(address(OR.getAuthority()), address(0), "authority");
    }

    function test_OR_authorize() external {
        vm.expectEmit();
        emit AuthorizedResolver.ResourceChanged(testLabel, 0, 1);
        uint256 resource = OR.authorize(testLabel, user, EACBaseRolesLib.ALL_ROLES, true);
        assertEq(resource, 1, "first");
        assertEq(OR.getResource(testLabel), resource, "get");
        assertEq(OR.getResourceMax(), resource, "max");
        assertTrue(OR.hasRoles(resource, EACBaseRolesLib.ALL_ROLES, user), "roles");
    }

    function test_AR_authorize() external {
        assertFalse(AR.isAuthority(testLabel, user));
        vm.expectRevert();
        vm.prank(user);
        AR.authorize(testLabel, user, EACBaseRolesLib.ALL_ROLES, true);

        authority.set(testLabel, user);
        assertTrue(AR.isAuthority(testLabel, user));
        vm.prank(user);
        uint256 resource = AR.authorize(testLabel, user, EACBaseRolesLib.ALL_ROLES, true);

        assertTrue(AR.hasRoles(resource, EACBaseRolesLib.ALL_ROLES, user));
    }

    function test_setAddr(uint256 coinType, bytes memory a) external {
        if (ENSIP19.isEVMCoinType(coinType)) {
            a = vm.randomBytes(20); // reverts otherwise
        }
        vm.expectEmit();
        emit AuthorizedResolver.AddressChanged(testLabel, coinType, a);
        OR.setAddr(testLabel, coinType, a);
        _testResolve(
            OR,
            testLabel,
            abi.encodeWithSelector(IAddressResolver.addr.selector, 0, coinType),
            abi.encode(a),
            ""
        );
    }

    function test_setAddr_eth() external {
        OR.setAddr(testLabel, COIN_TYPE_ETH, testAddress);
        _testResolve(
            OR,
            testLabel,
            abi.encodeWithSelector(IAddressResolver.addr.selector, 0, COIN_TYPE_ETH),
            abi.encode(testAddress),
            "address"
        );
        _testResolve(
            OR,
            testLabel,
            abi.encodeWithSelector(IAddrResolver.addr.selector, 0),
            abi.encode(testAddr),
            "addr"
        );
    }

    function test_setAddr_fallback(uint32 chain) external {
        vm.assume(chain < COIN_TYPE_DEFAULT);
        bytes memory a = vm.randomBytes(20);
        uint256 coinType = chain == 1 ? COIN_TYPE_ETH : (COIN_TYPE_DEFAULT | chain);
        OR.setAddr(testLabel, COIN_TYPE_DEFAULT, a);
        _testResolve(
            OR,
            testLabel,
            abi.encodeWithSelector(IAddressResolver.addr.selector, 0, coinType),
            abi.encode(a),
            ""
        );
    }

    function test_setAddr_zeroEVM() external {
        OR.setAddr(testLabel, COIN_TYPE_ETH, abi.encodePacked(address(0)));
        _testResolve(
            OR,
            testLabel,
            abi.encodeCall(IHasAddressResolver.hasAddr, (0, COIN_TYPE_DEFAULT)),
            abi.encode(false),
            "unset"
        );
        _testResolve(
            OR,
            testLabel,
            abi.encodeCall(IHasAddressResolver.hasAddr, (0, COIN_TYPE_ETH)),
            abi.encode(true),
            "null"
        );
    }

    function test_setAddr_zeroEVM_fallbacks() external {
        OR.setAddr(testLabel, COIN_TYPE_DEFAULT, abi.encodePacked(address(1))); // default
        OR.setAddr(testLabel, COIN_TYPE_DEFAULT | 1, abi.encodePacked(address(0))); // block
        OR.setAddr(testLabel, COIN_TYPE_DEFAULT | 2, abi.encodePacked(address(2))); // override
        _testResolve(
            OR,
            testLabel,
            abi.encodeWithSelector(IAddressResolver.addr.selector, 0, COIN_TYPE_DEFAULT | 1),
            abi.encode(abi.encodePacked(address(0))),
            "block"
        );
        _testResolve(
            OR,
            testLabel,
            abi.encodeWithSelector(IAddressResolver.addr.selector, 0, COIN_TYPE_DEFAULT | 2),
            abi.encode(abi.encodePacked(address(2))),
            "override"
        );
        _testResolve(
            OR,
            testLabel,
            abi.encodeWithSelector(IAddressResolver.addr.selector, 0, COIN_TYPE_DEFAULT | 3),
            abi.encode(abi.encodePacked(address(1))),
            "fallback"
        );
    }

    function test_setAddr_anyLabel_onePart() external {
        uint256 coinType = 1;

        // user cannot edit
        vm.expectRevert();
        vm.prank(user);
        OR.setAddr(testLabel, coinType, testAddress);

        // add control
        OR.authorizeEveryAddr(user, coinType, true);

        // user can edit
        vm.prank(user);
        OR.setAddr(testLabel, coinType, testAddress);

        // user can edit other labels
        vm.prank(user);
        OR.setAddr("abc", coinType, testAddress);

        // user cannot edit other addresses
        vm.expectRevert();
        vm.prank(user);
        OR.setAddr(testLabel, ~coinType, testAddress);

        // remove control
        OR.authorizeEveryAddr(user, coinType, false);

        // user cannot edit again
        vm.expectRevert();
        vm.prank(user);
        OR.setAddr(testLabel, coinType, testAddress);
    }

    function test_setAddr_oneLabel_onePart() external {
        string memory label = "abc";
        uint256 coinType = 1;

        // authorize user
        authority.set(label, user);
        vm.prank(user);
        AR.authorize(label, user, EACBaseRolesLib.ALL_ROLES, true);

        // friend cannot edit
        vm.expectRevert();
        vm.prank(friend);
        AR.setAddr(testLabel, coinType, testAddress);

        // add control
        vm.prank(user);
        AR.authorizeAddr(label, friend, coinType, true);

        // friend can edit
        vm.prank(friend);
        AR.setAddr(label, coinType, testAddress);

        // friend cannot edit other addresses
        vm.expectRevert();
        vm.prank(friend);
        AR.setAddr(label, ~coinType, testAddress);

        // friend cannot edit other labels
        vm.expectRevert();
        vm.prank(friend);
        AR.setAddr(testLabel, coinType, testAddress);

        // remove control
        vm.prank(user);
        AR.authorizeAddr(label, friend, coinType, false);

        // friend cannot edit again
        vm.expectRevert();
        vm.prank(friend);
        AR.setAddr(label, coinType, testAddress);
    }

    function test_setAddr_invalidEVM_tooShort() external {
        bytes memory v = new bytes(19);
        vm.expectRevert(abi.encodeWithSelector(AuthorizedResolver.InvalidEVMAddress.selector, v));
        OR.setAddr(testLabel, COIN_TYPE_ETH, v);
    }

    function test_setAddr_invalidEVM_tooLong() external {
        bytes memory v = new bytes(21);
        vm.expectRevert(abi.encodeWithSelector(AuthorizedResolver.InvalidEVMAddress.selector, v));
        OR.setAddr(testLabel, COIN_TYPE_ETH, v);
    }

    function test_setAddr_notAuthorized() external {
        vm.expectRevert(
            abi.encodeWithSelector(
                IEnhancedAccessControl.EACUnauthorizedAccountRoles.selector,
                OR.getResource(testLabel),
                AuthorizedResolverLib.ROLE_SET_ADDR,
                user
            )
        );
        vm.prank(user);
        OR.setAddr(testLabel, 0, "");
    }

    function _testResolve(
        AuthorizedResolver r,
        string memory label,
        bytes memory data,
        bytes memory expect,
        string memory blame
    ) internal view {
        assertEq(r.resolveSubdomain(label, data), expect, string.concat("sub:", blame));
        assertEq(r.resolve(NameCoder.ethName(label), data), expect, string.concat("ext:", blame));
    }
}

contract MockAuthority is IResolverAuthority {
    mapping(string => address) internal authorized;

    function set(string calldata label, address operator) external {
        authorized[label] = operator;
    }

    function isAuthorized(string calldata label, address operator) external view returns (bool) {
        return authorized[label] == operator;
    }
}
