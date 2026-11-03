// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IRegistry} from "./interfaces/IRegistry.sol";
import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";

/// @notice An mutable IRegistryURIRenderer which defers to an owned implementation.
contract BoxedURIRenderer is Ownable, ERC165, IRegistryURIRenderer {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Current renderer implementation.
    IRegistryURIRenderer public renderer;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Renderer was changed.
    /// @param renderer New renderer implementation.
    event RendererUpdated(IRegistryURIRenderer renderer);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param owner_ Contract owner.
    /// @param renderer_ Initial renderer implementation.
    constructor(address owner_, IRegistryURIRenderer renderer_) Ownable(owner_) {
        renderer = renderer_;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(IRegistryURIRenderer).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Change the renderer implementation.
    /// @param renderer_ New renderer implementation.
    function setRenderer(IRegistryURIRenderer renderer_) external onlyOwner {
        require(address(renderer) != address(renderer_));
        renderer = renderer_;
        emit RendererUpdated(renderer_);
    }

    /// @inheritdoc IRegistryURIRenderer
    function renderURI(IRegistry registry, uint256 tokenId) external view returns (string memory) {
        return renderer.renderURI(registry, tokenId);
    }
}
