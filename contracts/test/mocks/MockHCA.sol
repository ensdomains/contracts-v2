// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

/// @notice Mock ownable HCA implementation used by reverse registrar adapter tests.
contract MockHCA {
    address internal _owner;

    /// @notice Initializes the mock with an owner.
    /// @param owner_ Address returned by `owner()`.
    function initialize(address owner_) external {
        _owner = owner_;
    }

    /// @notice Returns the initialized owner.
    /// @return Address set during initialization.
    function owner() external view returns (address) {
        return _owner;
    }
}


/// @notice Mock HCA implementation whose owner lookup reverts.
contract MockRevertingHCA {
    /// @notice Raised when the mock owner lookup is unavailable.
    error OwnerUnavailable();

    /// @notice Always reverts to emulate an unavailable owner.
    function owner() external pure returns (address) {
        revert OwnerUnavailable();
    }
}
