// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {ContextUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ContextUpgradeable.sol";

import {HCAEquivalence} from "./HCAEquivalence.sol";

/// @dev Same as `HCAContext` but extends `ContextUpgradeable` for use in UUPS-upgradeable
///      contracts. Used by `PermissionedResolver`.
abstract contract HCAContextUpgradeable is ContextUpgradeable, HCAEquivalence {
    /// @dev Returns either the account owner of an HCA or the original sender
    function _msgSender() internal view virtual override(ContextUpgradeable) returns (address) {
        return _msgSenderWithHcaEquivalence();
    }
}
