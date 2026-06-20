// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

/// @notice The resolver profile cannot be answered.
/// @dev Error selector: `0x7b1c461b`
error UnsupportedResolverProfile(bytes4 selector);
