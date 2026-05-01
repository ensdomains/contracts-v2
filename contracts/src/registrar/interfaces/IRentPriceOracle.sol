// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for pricing registration and renewals.
/// @dev Interface selector: `0x0aa6305c`
interface IRentPriceOracle {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `label` is not valid.
    /// @dev Error selector: `0xdbfa2886`
    error NotValid(string label);

    /// @notice `duration` less than `minDuration`.
    /// @dev Error selector: `0xa096b844`
    error DurationTooShort(uint64 duration, uint64 minDuration);

    /// @notice `paymentToken` is not supported for payment.
    /// @dev Error selector: `0x02e2ae9e`
    error PaymentTokenNotSupported(address paymentToken);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Process the payment.
    /// @param from The payer account.
    /// @param paymentToken The payment token.
    /// @param amount The amount of `paymentToken`.
    function processPayment(
        address from,
        address paymentToken,
        uint256 amount
    ) external payable;

    /// @notice Determine registration price for `label`.
    /// @param label The name to price.
    /// @param available The duration the name has been available, in seconds.
    /// @param duration The duration to register for, in seconds.
    /// @param paymentToken The payment token.
    /// @return base The amount of `paymentToken` for the registration.
    /// @return premium The amount of `paymentToken` due to premium.
    function getRegisterPrice(
        string calldata label,
        uint64 available,
        uint64 duration,
        address paymentToken
    ) external view returns (uint256 base, uint256 premium);

    /// @notice Determine renewal price for `label`.
    /// @param label The name to price.
    /// @param expiry The current expiry, in seconds.
    /// @param duration The extension to price, in seconds.
    /// @param paymentToken The payment token.
    /// @return The amount of `paymentToken`.
    function getRenewPrice(
        string calldata label,
        uint64 expiry,
        uint64 duration,
        address paymentToken
    ) external view returns (uint256);
}
