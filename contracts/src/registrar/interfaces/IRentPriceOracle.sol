// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Interface for pricing registration and renewals.
/// @dev Interface selector: `0x53b53cee`.
interface IRentPriceOracle {
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
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `label` is not valid.
    /// @dev Error selector: `0xdbfa2886`
    error NotValid(string label);

    /// @notice `paymentToken` is not supported for payment.
    /// @dev Error selector: `0x02e2ae9e`
    error PaymentTokenNotSupported(IERC20 paymentToken);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Check if `paymentToken` is supported for payment.
    /// @param paymentToken The ERC-20 to check.
    /// @return `true` if `paymentToken` is supported.
    function isPaymentToken(IERC20 paymentToken) external view returns (bool);

    /// @notice Check if a `label` is valid.
    /// @param label The name.
    /// @return `true` if the `label` is valid.
    function isValid(string memory label) external view returns (bool);

    /// @notice Get rent price for `label`.
    /// @dev Reverts `PaymentTokenNotSupported` or `NotValid`.
    /// @param label The name.
    /// @param owner The new owner address.
    /// @param duration The duration to price, in seconds.
    /// @param paymentToken The ERC-20 to use.
    /// @return base The base price, relative to `paymentToken`.
    /// @return premium The premium price, relative to `paymentToken`.
    function rentPrice(
        string memory label,
        address owner,
        uint64 duration,
        IERC20 paymentToken
    ) external view returns (uint256 base, uint256 premium);
}
