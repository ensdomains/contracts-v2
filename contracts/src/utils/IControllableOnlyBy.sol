// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @dev Interface selector: `0xf5c237f7`
interface IControllableOnlyBy {
    /// @notice Returns whether this contract is controllable only by `account`.
    /// @param account The account to check.
    /// @return `true` if `account` is the sole controller or there is no controller.
    function isControllableOnlyBy(address account) external view returns (bool);
}
