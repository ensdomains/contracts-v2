// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for pricing registration and renewals.
/// @dev Interface selector: `0x480851dc`
interface IRentPriceOracle {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `label` is not valid.
    /// @dev Error selector: `0xdbfa2886`
    error NotValid(string label);

    /// @notice `paymentToken` is not supported for payment.
    /// @dev Error selector: `0x02e2ae9e`
    error PaymentTokenNotSupported(address paymentToken);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

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
    )
        external
        view
        returns (uint256 base, uint256 premium);

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
    )
        external
        view
        returns (uint256);

    /// @notice Check if `paymentToken` is supported for payment.
    /// @param paymentToken The payment token.
    /// @return Whether the payment token is supported.
    function isPaymentToken(address paymentToken) external view returns (bool);
}
