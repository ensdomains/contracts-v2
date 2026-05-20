// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Interface for the HCA factory.
/// @dev Interface selector: `0x1231c54c`
interface IHCAFactory {
    /// @notice Sets the deferred implementation users may explicitly select.
    /// @param implementation The deferred implementation address.
    function setDeferredImplementation(address implementation) external;

    /// @notice Explicitly pins the caller's HCA implementation.
    /// @param implementation The implementation the caller selects.
    function setAccountImplementation(address implementation) external;

    /// @notice Designates an existing SCA as the caller's HCA.
    /// @param hca The existing SCA to designate.
    /// @param implementation The expected approved implementation for the HCA.
    function setAccount(address hca, address implementation) external;

    /// @notice Returns whether an implementation is approved for HCA designation.
    /// @param implementation The implementation address to check.
    /// @return approved Whether the implementation is approved.
    function isApprovedImplementation(address implementation) external view returns (bool approved);

    /// @notice Returns the deferred implementation users may explicitly select.
    function deferredImplementation() external view returns (address implementation);

    /// @notice Returns an account's explicitly selected HCA implementation.
    /// @param account The account to inspect.
    /// @return implementation The selected implementation, or `address(0)` if unset.
    function accountImplementationOf(address account) external view returns (address implementation);

    /// @notice Returns the owner recorded for a designated HCA proxy.
    /// @param hca The HCA proxy address to look up.
    /// @return hcaOwner The owner address, or `address(0)` if the HCA is not registered.
    /// @dev Reverts if `hca` is not registered and has not explicitly pinned an implementation.
    function getAccountOwner(address hca) external view returns (address hcaOwner);
}
