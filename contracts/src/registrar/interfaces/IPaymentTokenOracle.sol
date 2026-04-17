// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Interface for payment tokens.
/// @dev Interface selector: `0x930eaddc`
interface IPaymentTokenOracle {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `paymentToken` is now supported.
    /// @param paymentToken The payment token added.
    event PaymentTokenAdded(IERC20 indexed paymentToken);

    /// @notice `paymentToken` is no longer supported.
    /// @param paymentToken The payment token removed.
    event PaymentTokenRemoved(IERC20 indexed paymentToken);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Check if `paymentToken` is supported for payment.
    /// @param paymentToken The ERC-20 to check.
    /// @return `true` if `paymentToken` is supported.
    function isPaymentToken(IERC20 paymentToken) external view returns (bool);
}
