// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title Standalone HCA Owner Funds Interface
/// @notice Token movements between a standalone HCA and its owner.
/// @dev Interface selector: `0x1bca80b5`
interface IStandaloneHCAOwnerFunds {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice An optional EIP-2612 permit from the owner to the account.
    /// @dev A zero `deadline` skips the permit and uses the owner's existing allowance.
    struct OwnerPermit {
        uint256 value;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Pulls tokens from the owner into the account.
    /// @dev Attempts `permit` when one is supplied and ignores its failure, so a permit that
    ///      another caller already submitted cannot stop the pull.
    /// @param token The token to pull.
    /// @param amount The amount to pull.
    /// @param permit The optional owner permit.
    function pullFromOwner(IERC20 token, uint256 amount, OwnerPermit calldata permit) external;

    /// @notice Sends the account's token balance above `keep` to the owner.
    /// @param token The token to return.
    /// @param keep The balance to leave in the account.
    function returnToOwner(IERC20 token, uint256 keep) external;
}
