// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for MigratedWrappedNameRegistry initialization and core functions
/// @dev Interface selector: `0xb08a2c9c`
interface IMigratedWrappedNameRegistry {
    function initialize(
        bytes calldata parentDnsEncodedName_,
        address ownerAddress_,
        uint256 ownerRoles_,
        address registrarAddress_
    ) external;
}
