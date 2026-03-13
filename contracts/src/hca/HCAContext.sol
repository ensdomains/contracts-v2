// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {Context} from "@openzeppelin/contracts/utils/Context.sol";

import {HCAEquivalence} from "./HCAEquivalence.sol";

/// @dev Drop-in replacement for OpenZeppelin's `Context` that overrides `_msgSender()` with
///      HCA-aware sender resolution. Inherit this instead of `Context` to make all `_msgSender()`
///      calls in the contract (including inherited modifiers and access control) automatically
///      resolve HCA proxy accounts to their owners.
abstract contract HCAContext is Context, HCAEquivalence {
    /// @dev Returns either the account owner of an HCA or the original sender
    function _msgSender() internal view virtual override returns (address) {
        return _msgSenderWithHcaEquivalence();
    }
}
