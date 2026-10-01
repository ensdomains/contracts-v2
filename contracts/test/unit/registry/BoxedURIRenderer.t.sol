// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {BoxedURIRenderer} from "~src/registry/BoxedURIRenderer.sol";
import {IRegistryURIRenderer} from "~src/registry/interfaces/IRegistryURIRenderer.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {MockURIRenderer} from "~test/mocks/MockURIRenderer.sol";

contract BoxedURIRendererTest is Test {
    BoxedURIRenderer boxedRenderer;
    MockURIRenderer firstRenderer;

    function setUp() external {
        firstRenderer = new MockURIRenderer("1");
        boxedRenderer = new BoxedURIRenderer(address(this), firstRenderer);
    }

    function test_constructor() external view {
        assertEq(boxedRenderer.owner(), address(this), "owner");
        assertEq(address(boxedRenderer.renderer()), address(firstRenderer), "renderer");
    }

    function test_supportsInterface() external view {
        assertTrue(
            ERC165Checker.supportsInterface(
                address(boxedRenderer),
                type(IRegistryURIRenderer).interfaceId
            ),
            "IRegistryURIRenderer"
        );
    }

    function test_renderURI(IRegistry registry, uint256 tokenId) external view {
        assertEq(
            boxedRenderer.renderURI(registry, tokenId),
            firstRenderer.renderURI(registry, tokenId)
        );
    }

    function test_setRenderer() external {
        MockURIRenderer r = new MockURIRenderer("2");

        vm.expectEmit();
        emit BoxedURIRenderer.RendererUpdated(r);
        boxedRenderer.setRenderer(r);

        assertEq(address(boxedRenderer.renderer()), address(r));
    }

    function test_setRenderer_notAuthorized() external {
        address actor = makeAddr("actor");
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, actor));
        vm.prank(actor);
        boxedRenderer.setRenderer(firstRenderer);
    }
}
