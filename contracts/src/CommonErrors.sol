// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @title Errors
/// @dev Common error definitions used across multiple contracts

/// @notice Expected valid owner.
/// @dev Error selector: `0x49e27cff`
error InvalidOwner();

/// @notice Thrown when a caller is not authorized to perform the requested operation
/// @dev Error selector: `0xd86ad9cf`
/// @param caller The address that attempted the unauthorized operation
error UnauthorizedCaller(address caller);

/// @notice Arrays have different lengths.
/// @param length1 The first array length.
/// @param length2 The second array length.
/// @dev Error selector: `0xfa5dbe08`
error ArrayLengthMismatch(uint256 length1, uint256 length2);
