// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for initializing a `PermissionedResolver`.
/// @dev Interface selector: `0x7058b559`
interface IPermissionedResolverInitializable {
    /// @notice Initialize the contract.
    /// @param rootAccount Account granted root roles.
    /// @param roleBitmap The roles granted to `rootAccount`.
    /// @param calls The calldata that avoids permission checks.
    function initialize(address rootAccount, uint256 roleBitmap, bytes[] calldata calls) external;
}
