// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {ITokenizedRegistry} from "./ITokenizedRegistry.sol";

/// @dev Interface selector: `0x75bed975`
interface IEmancipatableRegistry is ITokenizedRegistry {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Safe transfer is not allowed because the token is not emancipated.
    /// @dev Error selector: `0xb4733dce`
    error TransferUnsafeUntilTokenIsEmancipated(uint256 tokenId);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Determine if token is emancipated.
    /// @param anyId The labelhash, token ID, or resource.
    /// @return `true` if the token is emancipated.
    function isEmancipated(uint256 anyId) external view returns (bool);
}
