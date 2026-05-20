// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {HCAEquivalence} from "./HCAEquivalence.sol";

/// @dev Drop-in replacement for OpenZeppelin's `Context`.
///      HCA-aware sender resolution makes `_msgSender()` resolve HCA proxy accounts to their
///      owners. A configured factory may require non-HCA callers to explicitly select an HCA
///      implementation before calls using `_msgSender()` can proceed.
abstract contract HCAContext is Context, HCAEquivalence {
    /// @dev Returns either the account owner of an HCA or the original sender
    function _msgSender() internal view virtual override returns (address) {
        return _msgSenderWithHcaEquivalence();
    }
}
