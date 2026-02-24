// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Metadata URI generator for registries.
/// @dev Interface selector: `0x1675f455`
interface IRegistryMetadata {
    /**
     * @dev Fetches the token URI for a token ID.
     * @param tokenId The ID of the token to fetch a URI for.
     * @return The token URI for the token.
     */
    function tokenUri(uint256 tokenId) external view returns (string calldata);
}
