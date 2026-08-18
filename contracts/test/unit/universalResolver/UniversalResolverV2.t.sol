// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IAddrResolver} from "@ens/contracts/resolvers/profiles/IAddrResolver.sol";
import {IUniversalResolver} from "@ens/contracts/universalResolver/IUniversalResolver.sol";
import {ENSIP19, COIN_TYPE_ETH} from "@ens/contracts/utils/ENSIP19.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {
    IUniversalResolverExtended
} from "~src/universalResolver/interfaces/IUniversalResolverExtended.sol";
import {
    IUniversalResolverWithENSIP15
} from "~src/universalResolver/interfaces/IUniversalResolverWithENSIP15.sol";
import {
    IUniversalResolverWithENSIP15Extended
} from "~src/universalResolver/interfaces/IUniversalResolverWithENSIP15Extended.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {MockENSIP15} from "~test/mocks/MockENSIP15.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract UniversalResolverV2Test is V2Fixture {
    PermissionedResolver resolver;
    MockENSIP15 ensip15;

    function setUp() external {
        deployV2Fixture();
        ensip15 = new MockENSIP15();
        PermissionedResolver impl = new PermissionedResolver(address(this));
        bytes memory initData =
            abi.encodeCall(
                PermissionedResolver.initialize,
                (address(this), EACBaseRolesLib.ALL_ROLES, new bytes[](0))
            );
        resolver = PermissionedResolver(
            verifiableFactory.deployProxy(address(impl), uint256(keccak256(initData)), initData)
        );
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(
                address(universalResolver),
                type(IUniversalResolver).interfaceId
            ),
            "IUniversalResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(universalResolver),
                type(IUniversalResolverExtended).interfaceId
            ),
            "IUniversalResolverExtended"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(universalResolver),
                type(IUniversalResolverWithENSIP15).interfaceId
            ),
            "IUniversalResolverWithENSIP15"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(universalResolver),
                type(IUniversalResolverWithENSIP15Extended).interfaceId
            ),
            "IUniversalResolverWithENSIP15Extended"
        );
    }

    function test_findResolver_1LD() external {
        rootRegistry.register(
            "test",
            address(0),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        (address resolverAddress, , ) = universalResolver.findResolver(NameCoder.encode("test"));
        assertEq(address(resolver), resolverAddress);
    }

    function test_findResolver_test_eth() external {
        ethRegistry.register(
            "test",
            address(0),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        (address resolverAddress, , ) =
            universalResolver.findResolver(NameCoder.encode("test.eth"));
        assertEq(address(resolver), resolverAddress);
    }

    function test_normalize_empty() external view {
        (bool wasNorm, bytes memory name) = universalResolver.normalize("", ensip15);
        assertTrue(wasNorm);
        assertEq(name, NameCoder.encode(""));
    }

    function test_normalize_ETH() external view {
        (bool wasNorm, bytes memory name) = universalResolver.normalize("ETH", ensip15);
        assertFalse(wasNorm);
        assertEq(name, NameCoder.encode("eth"));
    }

    function test_normalize_TEST_eth() external view {
        (bool wasNorm, bytes memory name) = universalResolver.normalize("TEST.eth", ensip15);
        assertFalse(wasNorm);
        assertEq(name, NameCoder.encode("test.eth"));
    }

    function test_resolve_unnormalized() external {
        bytes memory name = NameCoder.encode("test.eth");
        ethRegistry.register(
            NameCoder.firstLabel(name),
            address(0),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        address addr = address(this);
        resolver.setAddr(NameCoder.namehash(name, 0), COIN_TYPE_ETH, abi.encodePacked(addr));
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalResolverWithENSIP15.NormalizationChangedName.selector,
                name,
                abi.encode(addr),
                resolver
            )
        );
        universalResolver.resolve(
            "TEST.eth",
            abi.encodeCall(IAddrResolver.addr, (bytes32(0))),
            ensip15
        );
    }

    function test_reverse_normalized() external {
        string memory primaryName = "test.eth";
        ethRegistry.register(
            NameCoder.firstLabel(NameCoder.encode(primaryName)),
            address(0),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        rootRegistry.register(
            "reverse",
            address(0),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        bytes memory encodedAddress = abi.encodePacked(address(this));
        bytes memory reverseName =
            NameCoder.encode(ENSIP19.reverseName(encodedAddress, COIN_TYPE_ETH));
        resolver.setName(NameCoder.namehash(reverseName, 0), primaryName);
        resolver.setAddr(
            NameCoder.namehash(NameCoder.encode(primaryName), 0),
            COIN_TYPE_ETH,
            encodedAddress
        );
        (string memory primary, , ) =
            universalResolver.reverse(encodedAddress, COIN_TYPE_ETH, ensip15);
        assertEq(primaryName, primary);
    }

    function test_reverse_unnormalized() external {
        rootRegistry.register(
            "reverse",
            address(0),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        string memory primaryName = "TEST.eth";
        bytes memory encodedAddress = abi.encodePacked(address(this));
        bytes memory reverseName =
            NameCoder.encode(ENSIP19.reverseName(encodedAddress, COIN_TYPE_ETH));
        resolver.setName(NameCoder.namehash(reverseName, 0), primaryName);
        vm.expectRevert(
            abi.encodeWithSelector(
                IUniversalResolverWithENSIP15.PrimaryNameNotNormalized.selector,
                primaryName,
                0
            )
        );
        universalResolver.reverse(encodedAddress, COIN_TYPE_ETH, ensip15);
    }

    function test_reverse_withoutENSIP15() external {
        string memory primaryName = "TEST.eth";
        ethRegistry.register(
            NameCoder.firstLabel(NameCoder.encode(primaryName)),
            address(0),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        rootRegistry.register(
            "reverse",
            address(0),
            IRegistry(address(0)),
            address(resolver),
            0,
            type(uint64).max
        );
        bytes memory encodedAddress = abi.encodePacked(address(this));
        bytes memory reverseName =
            NameCoder.encode(ENSIP19.reverseName(encodedAddress, COIN_TYPE_ETH));
        resolver.setName(NameCoder.namehash(reverseName, 0), primaryName);
        resolver.setAddr(
            NameCoder.namehash(NameCoder.encode(primaryName), 0),
            COIN_TYPE_ETH,
            encodedAddress
        );
        (string memory primary, , ) = universalResolver.reverse(encodedAddress, COIN_TYPE_ETH);
        assertEq(primaryName, primary);
    }
}
