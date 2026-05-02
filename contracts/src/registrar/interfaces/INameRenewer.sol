// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Interface for renewing names.
/// @dev Interface selector: `0x89d779c3`
interface INameRenewer {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `label` was extended by `duration`.
    /// @param tokenId The registry token id.
    /// @param label The name of the renewal.
    /// @param duration The duration extension, in seconds.
    /// @param newExpiry The new expiry, in seconds.
    /// @param paymentToken The payment token.
    /// @param referrer The referrer hash.
    /// @param amount The amount of `paymentToken`.
    event NameRenewed(
        uint256 indexed tokenId,
        string label,
        uint64 duration,
        uint64 newExpiry,
        IERC20 paymentToken,
        bytes32 indexed referrer,
        uint256 amount
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `label` cannot be renewed.
    /// @dev Error selector: `0x1caefaa0`
    error NameNotRenewable(string label);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Renew a name.
    /// @dev Should emit `NameRenewed`.
    /// @param label The name to renew.
    /// @param duration The duration extension, in seconds.
    /// @param paymentToken The payment token.
    /// @param referrer The referrer hash.
    function renew(
        string memory label,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external;
}
