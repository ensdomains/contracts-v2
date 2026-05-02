// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ICommitRevealRegistrar} from "./ICommitRevealRegistrar.sol";
import {INameRenewer} from "./INameRenewer.sol";

/// @notice Interface for registering and renewing in ENSv2.
/// @dev Interface selector: `0x6bb38049`
interface IETHRegistrar is ICommitRevealRegistrar, INameRenewer {
    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `duration` less than `minDuration`.
    /// @dev Error selector: `0xa096b844`
    error DurationTooShort(uint64 duration, uint64 minDuration);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Check if `label` is available.
    /// @param label The name to check.
    /// @return `true` if the `label` is registerable, otherwise renewable.
    function isAvailable(string memory label) external view returns (bool);

    /// @notice Determine remaining grace period.
    /// @dev Defined over `[expiry, expiry + GRACE_PERIOD)`.
    /// @param label The name to check.
    /// @return The remaining grace period, in seconds.
    function getRemainingGracePeriod(string calldata label) external view returns (uint64);

    /// @notice Determine register price for a name.
    /// @param label The name to register.
    /// @param duration The registration duration, in seconds.
    /// @param paymentToken The payment token.
    /// @return base The amount of `paymentToken` for registration.
    /// @return premium The amount of `paymentToken` due to premium.
    function getRegisterPrice(
        string calldata label,
        uint64 duration,
        IERC20 paymentToken
    ) external view returns (uint256 base, uint256 premium);

    /// @notice Determine renew price for a name.
    /// @param label The name to renew.
    /// @param duration The duration extension, in seconds.
    /// @param paymentToken The payment token.
    /// @return The amount of `paymentToken`.
    function getRenewPrice(
        string calldata label,
        uint64 duration,
        IERC20 paymentToken
    ) external view returns (uint256);

    /// @notice Post-expiry period where still renewable and not available, in seconds.
    function GRACE_PERIOD() external view returns (uint64);
}
