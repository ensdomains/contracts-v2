// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {StaticURIRenderer} from "~src/registry/StaticURIRenderer.sol";
import {IRegistryURIRenderer} from "~src/registry/interfaces/IRegistryURIRenderer.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {LibString} from "~src/utils/LibString.sol";

contract StaticURIRendererTest is Test {
    StaticURIRenderer render;

    string constant PREFIX = "a";
    string constant AFTER_REGISTRY = "b";
    string constant AFTER_TOKEN = "c";

    function setUp() external {
        render = new StaticURIRenderer(PREFIX, AFTER_REGISTRY, AFTER_TOKEN);
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(address(render), type(IRegistryURIRenderer).interfaceId),
            "IRegistryURIRenderer"
        );
    }

    function test_renderURI() external view {
        assertEq(
            render.renderURI(IRegistry(address(1)), 2),
            "a0000000000000000000000000000000000000001b2c"
        );
    }

    function test_renderURI_fuzzParams(IRegistry registry, uint256 tokenId) external view {
        assertEq(
            render.renderURI(registry, tokenId),
            string.concat(
                PREFIX,
                LibString.toAddressString(address(registry)),
                AFTER_REGISTRY,
                LibString.toString(tokenId),
                AFTER_TOKEN
            )
        );
    }

    function test_renderURI_fuzzFragments(
        string memory prefix,
        string memory afterRegistry,
        string memory afterToken
    )
        external
    {
        assertEq(
            new StaticURIRenderer(prefix, afterRegistry, afterToken).renderURI(
                IRegistry(address(1)),
                2
            ),
            string.concat(
                prefix,
                "0000000000000000000000000000000000000001",
                afterRegistry,
                "2",
                afterToken
            )
        );
    }
}
