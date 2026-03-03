// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC1155} from "@openzeppelin/contracts/token/ERC1155/IERC1155.sol";

/// @notice Interface for ERC1155Singleton
/// @dev Interface selector: `0x6352211e`
interface IERC1155Singleton is IERC1155 {
    /// @notice Returns the owner of a token.
    /// @param id The token ID.
    /// @return owner The owner of the token.
    function ownerOf(uint256 id) external view returns (address owner);
}
