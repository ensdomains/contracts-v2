// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @dev Defines the two fundamental bitmasks used by `EnhancedAccessControl`'s nybble-packed role system.
///
/// `ALL_ROLES`: a mask with bit 0 of every nybble set (`0x1111...`), representing one unit in
/// each of the 64 role slots (32 regular + 32 admin). Used for validation (checking no bits
/// outside valid positions are set) and for revoking all roles.
///
/// `ADMIN_ROLES`: same pattern but only in the upper 128 bits (`0x1111...0000...`), masking
/// just the 32 admin role slots. Used to extract which admin roles an account holds.
///
library EACBaseRolesLib {
    /// @dev Mask with bit 0 set in every nybble — represents one unit per role slot across all 64 slots.
    uint256 internal constant ALL_ROLES =
        0x1111111111111111111111111111111111111111111111111111111111111111;

    /// @dev Mask selecting only the 32 admin role nybbles (upper 128 bits).
    uint256 internal constant ADMIN_ROLES =
        0x1111111111111111111111111111111100000000000000000000000000000000;
}
