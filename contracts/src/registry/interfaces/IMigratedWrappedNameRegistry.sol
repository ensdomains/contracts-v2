// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

/// @notice Interface for MigratedWrappedNameRegistry initialization and core functions
/// @dev Interface selector: `0xb08a2c9c`
interface IMigratedWrappedNameRegistry {
    /// @notice Initializes a proxy instance of `MigratedWrappedNameRegistry`.
    /// @param parentDnsEncodedName_ DNS wire-format encoded name of the parent domain.
    /// @param ownerAddress_ Address that will own this subregistry.
    /// @param ownerRoles_ Role bitmap to grant to the owner.
    /// @param registrarAddress_ Address to grant the registrar role to.
    function initialize(
        bytes calldata parentDnsEncodedName_,
        address ownerAddress_,
        uint256 ownerRoles_,
        address registrarAddress_
    ) external;
}
