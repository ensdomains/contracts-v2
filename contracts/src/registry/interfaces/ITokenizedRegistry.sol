// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC1155Singleton} from "../../erc1155/interfaces/IERC1155Singleton.sol";

import {IRegistry} from "./IRegistry.sol";

/// @notice A tokenized registry.
/// @dev Interface selector: `0x91b3c037`
interface ITokenizedRegistry is IRegistry, IERC1155Singleton {
    /// @notice Fetches the token ID for a label.
    /// @param label The label to query.
    /// @return The token ID of the label.
    function findTokenId(string calldata label) external view returns (uint256);
}
