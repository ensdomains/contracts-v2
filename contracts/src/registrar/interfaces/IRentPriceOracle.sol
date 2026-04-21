// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPaymentTokenOracle} from "./IPaymentTokenOracle.sol";

/// @notice Interface for pricing registration and renewals.
/// @dev Interface selector: `0xff1a5934`
interface IRentPriceOracle is IPaymentTokenOracle {
    /// @notice Get registration price for `label`.
    /// @dev Reverts `PaymentTokenNotSupported`.
    /// @param label The name to register.
    /// @param available The duration the name has been available, in seconds.
    /// @param duration The duration to register for, in seconds.
    /// @param paymentToken The ERC-20 to use.
    /// @return base The base price, relative to `paymentToken` or 0 if invalid.
    /// @return premium The premium price, relative to `paymentToken`.
    function registerPrice(
        string memory label,
        uint64 available,
        uint64 duration,
        IERC20 paymentToken
    ) external view returns (uint256 base, uint256 premium);

    /// @notice Get renewal price for `label`.
    /// @dev Reverts `PaymentTokenNotSupported`.
    /// @param label The name to renew.
    /// @param remaining The current duration to price, in seconds.
    /// @param baseExtension The extension at base price, in seconds.
    /// @param extension The extension at computed price, in seconds.
    /// @param paymentToken The ERC-20 to use.
    /// @return The price, relative to `paymentToken`, or 0 if invalid.
    function renewPrice(
        string memory label,
        uint64 remaining,
        uint64 baseExtension,
        uint64 extension,
        IERC20 paymentToken
    ) external view returns (uint256);
}
