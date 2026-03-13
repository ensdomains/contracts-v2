// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";

import {IEnhancedAccessControl} from "../../access-control/interfaces/IEnhancedAccessControl.sol";

/// @dev Interface selector: `0x2c7442c9`
interface IPermissionedResolver is IExtendedResolver, IEnhancedAccessControl {
    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice An alias was changed.
    /// @param indexedFromName The source DNS-encoded name. (indexed bytes, hashed)
    /// @param indexedToName The destination DNS-encoded name. (indexed bytes, hashed)
    /// @param fromName The source DNS-encoded name.
    /// @param toName The destination DNS-encoded name.
    event AliasChanged(
        bytes indexed indexedFromName,
        bytes indexed indexedToName,
        bytes fromName,
        bytes toName
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The resolver profile cannot be answered.
    /// @dev Error selector: `0x7b1c461b`
    error UnsupportedResolverProfile(bytes4 selector);

    /// @notice The address could not be converted to `address`.
    /// @dev Error selector: `0x8d666f60`
    error InvalidEVMAddress(bytes addressBytes);

    /// @notice The coin type is not a power of 2.
    /// @dev Error selector: `0x5742bb26`
    error InvalidContentType(uint256 contentType);

    ////////////////////////////////////////////////////////////////////////
    // Functions
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initialize the contract.
    /// @param admin The resolver owner.
    /// @param roleBitmap The roles granted to `admin`.
    function initialize(address admin, uint256 roleBitmap) external;

    /// @notice Create an alias from `fromName` to `toName`.
    /// @param fromName The source DNS-encoded name.
    /// @param toName The destination DNS-encoded name.
    function setAlias(bytes calldata fromName, bytes calldata toName) external;

    /// @notice Determine which name is queried when `fromName` is resolved.
    /// @param fromName The source DNS-encoded name.
    /// @return toName The destination DNS-encoded name or empty if not aliased.
    function getAlias(bytes memory fromName) external view returns (bytes memory toName);
}
