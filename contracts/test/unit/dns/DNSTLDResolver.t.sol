// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {GatewayProvider} from "@ens/contracts/ccipRead/GatewayProvider.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IHCAFactoryBasic} from "~src/hca/interfaces/IHCAFactoryBasic.sol";
import {PermissionedRegistry, IRegistryMetadata} from "~src/registry/PermissionedRegistry.sol";
import {DNSTLDResolver, ENS, IRegistry, DNSSEC, HexUtils} from "~src/dns/DNSTLDResolver.sol";

// coverage:ignore-next-line
contract MockDNS is DNSTLDResolver {
    constructor(
        IRegistry rootRegistry
    )
        DNSTLDResolver(
            ENS(address(0)),
            address(0),
            rootRegistry,
            DNSSEC(address(0)),
            new GatewayProvider(address(1), new string[](0)),
            new GatewayProvider(address(1), new string[](0))
        )
    {}
    function readTXT(bytes memory v) external pure returns (bytes memory) {
        return _readTXT(v, 0, v.length);
    }
    function readTXT(
        bytes memory v,
        uint256 pos,
        uint256 end
    ) external pure returns (bytes memory) {
        return _readTXT(v, pos, end);
    }
    // function trim(bytes memory v) external pure returns (bytes memory) {
    //     return _trim(abi.encodePacked(v));
    // }
    function parseResolver(bytes memory v) external view returns (address) {
        return _parseResolver(v);
    }
}

contract DNSTLDResolverTest is Test, ERC1155Holder, IAddrResolver {
    PermissionedRegistry rootRegistry;
    MockDNS dns;

    function setUp() external {
        rootRegistry = new PermissionedRegistry(
            IHCAFactoryBasic(address(0)),
            IRegistryMetadata(address(0)),
            address(this),
            EACBaseRolesLib.ALL_ROLES
        );
        dns = new MockDNS(rootRegistry);
    }

    function test_readTXT() external view {
        assertEq(dns.readTXT(""), "");
        assertEq(dns.readTXT("\x01a"), "a");
        assertEq(dns.readTXT("\x00\x01a"), "a");
        assertEq(dns.readTXT("\x01a\x01b"), "ab");
        assertEq(dns.readTXT("\x01a\x00\x02bc"), "abc");
    }

    function test_readTXT_invalid() external {
        vm.expectRevert();
        dns.readTXT("\x01");
        vm.expectRevert();
        dns.readTXT("\x01a\x01");
        vm.expectRevert();
        dns.readTXT("\x00a");
    }

    function testFuzz_readTXT(uint16 pad) external {
        bytes memory v = new bytes(pad);
        bytes memory u;
        for (uint256 i = vm.randomUint(5); i > 0; i--) {
            bytes memory rng = vm.randomBytes(vm.randomUint(0, 255));
            v = abi.encodePacked(v, uint8(rng.length), rng);
            u = abi.encodePacked(u, rng);
        }
        assertEq(dns.readTXT(v, pad, v.length), u);
    }

    // function test_trim() external view {
    //     assertEq(dns.trim("a"), "a");
    //     assertEq(dns.trim("a  "), "a");
    //     assertEq(dns.trim("  a"), "a");
    //     assertEq(dns.trim(" a "), "a");
    // }

    // function testFuzz_trim(uint8 na, uint8 nb, uint8 n) external view {
    //     bytes memory a = new bytes(na);
    //     for (uint256 i; i < na; i++) a[i] = " ";
    //     bytes memory b = new bytes(nb);
    //     for (uint256 i; i < nb; i++) b[i] = " ";
    //     bytes memory v = new bytes(n);
    //     assertEq(dns.trim(abi.encodePacked(a, v, b)), v);
    // }

    function test_parseResolver_address() external view {
        assertEq(
            dns.parseResolver("0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e"),
            0x00000000000C2E074eC69A0dFb2997BA6C7d2e1e
        );
    }

    // mock IAddrResolver
    function addr(bytes32) public pure returns (address payable) {
        return payable(address(1));
    }

    function test_parseResolver_name() external {
        rootRegistry.register(
            "abc",
            address(this),
            IRegistry(address(0)),
            address(this),
            EACBaseRolesLib.ALL_ROLES,
            uint64(block.timestamp) + 86400
        );
        assertEq(dns.parseResolver("abc"), addr(bytes32(0)));
    }

    function testFuzz_parseResolver_address(address a) external view {
        assertEq(dns.parseResolver(abi.encodePacked("0x", HexUtils.addressToHex(a))), a);
    }
}
