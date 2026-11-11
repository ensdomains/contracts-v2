// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @title Permit2 Allowance Transfer Interface
/// @notice The subset of Permit2's allowance transfers used to pull an HCA owner's tokens.
/// @dev Interface selector: `0x1da03066`
interface IPermit2AllowanceTransfer {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @notice The allowance granted by a signed permit.
    struct PermitDetails {
        address token;
        uint160 amount;
        uint48 expiration;
        uint48 nonce;
    }

    /// @notice A signed allowance for one token and one spender.
    struct PermitSingle {
        PermitDetails details;
        address spender;
        uint256 sigDeadline;
    }

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Sets a spender's allowance from the owner's signed permit.
    /// @param owner The token owner who signed the permit.
    /// @param permitSingle The signed allowance.
    /// @param signature The owner's signature over the permit.
    function permit(address owner, PermitSingle calldata permitSingle, bytes calldata signature)
        external;

    /// @notice Transfers tokens against the caller's allowance from `from`.
    /// @param from The token owner.
    /// @param to The recipient.
    /// @param amount The amount to transfer.
    /// @param token The token to transfer.
    function transferFrom(address from, address to, uint160 amount, address token) external;
}
