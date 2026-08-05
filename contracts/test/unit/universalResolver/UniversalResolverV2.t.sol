// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IUniversalResolver} from "@ens/contracts/universalResolver/IUniversalResolver.sol";
import {ENSIP19, COIN_TYPE_ETH} from "@ens/contracts/utils/ENSIP19.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {LibRegistry} from "~src/universalResolver/libraries/LibRegistry.sol";
import {IUniversalResolverV2} from "~src/universalResolver/interfaces/IUniversalResolverV2.sol";
import {PermissionedResolver} from "~src/resolver/PermissionedResolver.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract UniversalResolverV2Test is V2Fixture {
    PermissionedResolver resolver;

    function setUp() external {
        deployV2Fixture();
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
                type(IUniversalResolverV2).interfaceId
            ),
            "IUniversalResolverV2"
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

    function test_normalize() external view {
        assertEq(universalResolver.normalize(NameCoder.encode("")), NameCoder.encode(""));
        assertEq(universalResolver.normalize(NameCoder.encode("ETH")), NameCoder.encode("eth"));
        assertEq(
            universalResolver.normalize(NameCoder.encode("TEST.ETH")),
            NameCoder.encode("test.eth")
        );
    }

    function test_reverse_normalized() external {
        ethRegistry.register(
            "test",
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
        string memory primaryName = "test.eth";
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

    function test_reverse_unnormalized() external {
        ethRegistry.register(
            "TEST",
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
        string memory primaryName = "TEST.eth";
        bytes memory encodedAddress = abi.encodePacked(address(this));
        bytes memory reverseName =
            NameCoder.encode(ENSIP19.reverseName(encodedAddress, COIN_TYPE_ETH));
        resolver.setName(NameCoder.namehash(reverseName, 0), primaryName);
        resolver.setAddr(
            NameCoder.namehash(NameCoder.encode(primaryName), 0),
            COIN_TYPE_ETH,
            encodedAddress
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                LibRegistry.NotNormalized.selector,
                NameCoder.encode(primaryName),
                0
            )
        );
        universalResolver.reverse(encodedAddress, COIN_TYPE_ETH);
    }
}
