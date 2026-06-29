// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @title IHCA
/// @notice Minimal consumer interface for an ens-modules Hidden Contract Account (HCA).
interface IHCA {
    /// @notice Reports whether `owner` is a current (non-expired) owner of this HCA.
    /// @param owner The address to check.
    /// @return True iff `owner` is in the account's owner set and not expired.
    function isOwner(address owner) external view returns (bool);
}
