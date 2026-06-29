// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Mock HCA implementation used by reverse registrar adapter tests.
/// @dev Mirrors the ens-modules `HCA.isOwner(address)` semantics: returns true
///      iff `owner_` is the current, non-expired owner of the account.
contract MockHCA {
    address internal _owner;
    bool internal _expired;

    /// @notice Initializes the mock with an owner.
    /// @param owner_ Address returned by `owner()`.
    function initialize(address owner_) external {
        _owner = owner_;
    }

    /// @notice Toggles whether the owner is treated as expired.
    /// @param expired_ When true, `isOwner` returns false for every address.
    function setExpired(bool expired_) external {
        _expired = expired_;
    }

    /// @notice Reports whether `owner_` is the current, non-expired owner.
    /// @param owner_ The address to check.
    /// @return True iff `owner_` matches the initialized, non-expired owner.
    function isOwner(address owner_) external view returns (bool) {
        return !_expired && owner_ != address(0) && owner_ == _owner;
    }
}
