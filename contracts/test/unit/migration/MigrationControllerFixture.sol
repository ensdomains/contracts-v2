// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {ERC1155} from "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {ENSV1Resolver} from "~src/resolver/ENSV1Resolver.sol";
import {ENSV2Resolver} from "~src/resolver/ENSV2Resolver.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {V1Fixture} from "~test/fixtures/V1Fixture.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

// initial gas analysis
// * Unwrapped: 160300
// * Unlocked: 179367
// * Locked: 659168 (~500k for WrapperRegistry)

contract MigrationControllerFixture is V1Fixture, V2Fixture {
    ENSV1Resolver ensV1Resolver;
    ENSV2Resolver ensV2Resolver;
    MockERC1155 dummy1155;

    string testLabel = "test";
    address testResolver = makeAddr("resolver");
    IRegistry testRegistry = IRegistry(makeAddr("registry"));
    address premigrationController = makeAddr("premigrationController");

    function setUp() public virtual {
        deployV1Fixture();
        deployV2Fixture();
        ensV1Resolver = new ENSV1Resolver(registryV1, batchGatewayProvider);
        ensV2Resolver = new ENSV2Resolver(rootRegistry, batchGatewayProvider);
        dummy1155 = new MockERC1155();
        ethRegistrarV1.setResolver(address(ensV2Resolver));
    }

    /// @dev Ensure premigration has occurred.
    function registerUnwrapped(
        string memory label
    ) public override returns (bytes memory name, uint256 tokenId) {
        (name, tokenId) = super.registerUnwrapped(label);
        if (address(premigrationController) != address(0)) {
            vm.prank(premigrationController);
            ethRegistry.register(
                label,
                address(0), // reserve
                IRegistry(address(0)),
                address(ensV1Resolver), // fallback
                0,
                uint64(ethRegistrarV1.nameExpires(tokenId))
            );
        }
    }

    /// @dev Check resolver and fallback logic.
    function checkResolution(
        bytes memory name,
        address resolverV1,
        address resolverV2
    ) public view {
        assertEq(findResolverV1(name), resolverV1, "findResolverV1");
        assertEq(findResolverV2(name), resolverV2, "findResolverV2");
        if (resolverV2 == address(ensV1Resolver)) {
            (address r, ) = ensV1Resolver.getResolver(name);
            assertEq(r, resolverV1, "compositeV1");
        } else if (resolverV1 == address(ensV2Resolver)) {
            (address r, ) = ensV2Resolver.getResolver(name);
            assertEq(r, resolverV2, "compositeV2");
            assertEq(registryV1.resolver(NameCoder.namehash(name, 0)), address(0), "resolverV1");
        }
    }

    function _label(uint256 i) internal view returns (string memory) {
        return string.concat(testLabel, vm.toString(i));
    }

    function _soon() internal view returns (uint64) {
        return uint64(block.timestamp + 1000);
    }
}

contract MockERC1155 is ERC1155 {
    uint256 _id;
    constructor() ERC1155("") {}
    function mint(address to) external returns (uint256) {
        _mint(to, _id, 1, "");
        return _id++;
    }
}
