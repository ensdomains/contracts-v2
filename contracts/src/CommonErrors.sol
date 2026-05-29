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

/// @notice Thrown when a propagation callback is invoked for a parent token that does not
///         correspond to this contract's wrapped name.
/// @dev Error selector: `0x52c405e0`
/// @param parentTokenId The parent registry token ID that triggered the call.
error WrongParentToken(uint256 parentTokenId);
