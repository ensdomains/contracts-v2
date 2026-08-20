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
    IPermissionedResolverInitializable,
    Grant
} from "~src/resolver/interfaces/IPermissionedResolverInitializable.sol";
import {
    IUniversalResolverExtended
} from "~src/universalResolver/interfaces/IUniversalResolverExtended.sol";
import {
    INormalizedUniversalResolver
} from "~src/universalResolver/interfaces/INormalizedUniversalResolver.sol";
import {
    INormalizedUniversalResolverExtended
} from "~src/universalResolver/interfaces/INormalizedUniversalResolverExtended.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {MockENSIP15} from "~test/mocks/MockENSIP15.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract UniversalResolverV2Test is V2Fixture {
    PermissionedResolver resolver;
    MockENSIP15 ensip15;

    address resolverAddress = makeAddr("resolver");

    function setUp() external {
        deployV2Fixture();
        ensip15 = new MockENSIP15();
        PermissionedResolver impl = new PermissionedResolver(address(this));
        Grant[] memory grants = new Grant[](1);
        grants[0] = Grant(address(this), EACBaseRolesLib.ALL_ROLES);
        bytes memory initData =
            abi.encodeCall(IPermissionedResolverInitializable.initialize, (grants, new bytes[](0)));
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
                type(INormalizedUniversalResolver).interfaceId
            ),
            "INormalizedUniversalResolver"
        );
        assertTrue(
            ERC165Checker.supportsInterface(
                address(universalResolver),
                type(INormalizedUniversalResolverExtended).interfaceId
            ),
            "INormalizedUniversalResolverExtended"
        );
    }

    function test_isENSv2() external view {
        assertTrue(universalResolver.isENSv2());
    }

    function test_findResolver_root() external view {
        (address r, , ) = universalResolver.findResolver(NameCoder.encode(""));
        assertEq(r, address(0));
    }

    function test_findResolver_eth() external {
        rootRegistry.setResolver(rootRegistry.findTokenId("eth"), address(resolver));
        (address r, , ) = universalResolver.findResolver(NameCoder.encode("eth"));
        assertEq(r, address(resolver));
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
        (address r, , ) = universalResolver.findResolver(NameCoder.encode("test.eth"));
        assertEq(r, address(resolver));
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

    function test_resolveWithENSIP15_normalized(bytes32 anyNode) external {
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
        resolver.setAddress(name, COIN_TYPE_ETH, abi.encodePacked(addr));
        (bytes memory result, address r) =
            universalResolver.resolveWithENSIP15(
                NameCoder.decode(name),
                abi.encodeCall(IAddrResolver.addr, (bytes32(anyNode))),
                ensip15
            );
        assertEq(result, abi.encode(addr));
        assertEq(r, address(resolver));
    }

    function test_resolveWithENSIP15_unnormalized() external {
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
        resolver.setAddress(name, COIN_TYPE_ETH, abi.encodePacked(addr));
        vm.expectRevert(
            abi.encodeWithSelector(
                INormalizedUniversalResolver.NormalizationChangedName.selector,
                name,
                abi.encode(addr),
                resolver
            )
        );
        universalResolver.resolveWithENSIP15(
            "TEST.eth",
            abi.encodeCall(IAddrResolver.addr, (bytes32(0))),
            ensip15
        );
    }

    function test_reverseWithENSIP15_normalized() external {
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
        resolver.setName(reverseName, primaryName);
        resolver.setAddress(NameCoder.encode(primaryName), COIN_TYPE_ETH, encodedAddress);
        (string memory primary, , ) =
            universalResolver.reverseWithENSIP15(encodedAddress, COIN_TYPE_ETH, ensip15);
        assertEq(primaryName, primary);
    }

    function test_reverseWithENSIP15_unnormalized() external {
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
        resolver.setName(reverseName, primaryName);
        vm.expectRevert(
            abi.encodeWithSelector(
                INormalizedUniversalResolver.PrimaryNameNotNormalized.selector,
                primaryName
            )
        );
        universalResolver.reverseWithENSIP15(encodedAddress, COIN_TYPE_ETH, ensip15);
    }

    function test_reverse_unnormalized() external {
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
        resolver.setName(reverseName, primaryName);
        resolver.setAddress(NameCoder.encode(primaryName), COIN_TYPE_ETH, encodedAddress);
        (string memory primary, , ) = universalResolver.reverse(encodedAddress, COIN_TYPE_ETH);
        assertEq(primaryName, primary);
    }
}
