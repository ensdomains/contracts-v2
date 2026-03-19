// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IRegistry} from "./IRegistry.sol";

/// @dev Interface selector: `0x6c55e19b`
interface IRegistryURIRenderer {
    /// @notice Generate URI for `tokenId` from `registry`.
    /// @param registry The registry.
    /// @param tokenId The token ID in the registry.
    /// @return The generated URI.
    function renderURI(IRegistry registry, uint256 tokenId) external view returns (string memory);
}
