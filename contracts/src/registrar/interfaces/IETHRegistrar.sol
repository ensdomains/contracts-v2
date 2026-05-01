// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {INameRegistrar} from "./INameRegistrar.sol";
import {INameRenewer} from "./INameRenewer.sol";

/// @notice Interface for registering and renewing in ENSv2.
/// @dev Interface selector: `0x3c420101`
interface IETHRegistrar is INameRegistrar, INameRenewer {
    /// @notice Check if name is in grace.
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
        address paymentToken
    ) external view returns (uint256 base, uint256 premium);

    /// @notice Determine renew price for a name.
    /// @param label The name to renew.
    /// @param duration The duration extension, in seconds.
    /// @param paymentToken The payment token.
    /// @return The amount of `paymentToken`.
    function getRenewPrice(
        string calldata label,
        uint64 duration,
        address paymentToken
    ) external view returns (uint256);
}
