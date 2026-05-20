// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

import {IHCAFactoryBasic} from "./interfaces/IHCAFactoryBasic.sol";

/// @title HCA Deferred Implementation
/// @notice Minimal implementation for HCAs whose final account implementation is deferred.
/// @dev The recorded HCA owner may directly upgrade the proxy to a concrete implementation.
contract HCADeferredImplementation {
    ////////////////////////////////////////////////////////////////////////
    // Constants & Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @dev ERC-1967 implementation storage slot.
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The HCA factory used to resolve the authorized account owner.
    IHCAFactoryBasic public immutable HCA_FACTORY;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when the proxy implementation is upgraded.
    /// @param implementation The new implementation address.
    event Upgraded(address indexed implementation);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when the HCA factory address is zero.
    /// @dev Error selector: `0x841d6202`
    error HCAFactoryCannotBeZero();

    /// @notice Thrown when an HCA has no recorded owner.
    /// @param hca The HCA without an owner.
    /// @dev Error selector: `0x46652664`
    error HCAOwnerNotSet(address hca);

    /// @notice Thrown when an upgrade is attempted by an unauthorized caller.
    /// @param caller The unauthorized caller.
    /// @param owner The authorized HCA owner.
    /// @dev Error selector: `0x057ff497`
    error CallerNotHCAOwner(address caller, address owner);

    /// @notice Thrown when a target implementation has no code.
    /// @param implementation The invalid implementation.
    /// @dev Error selector: `0xbcc62262`
    error HCAImplementationHasNoCode(address implementation);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the deferred implementation.
    /// @param hcaFactory The HCA factory used to resolve account ownership.
    constructor(IHCAFactoryBasic hcaFactory) {
        if (address(hcaFactory) == address(0))
            revert HCAFactoryCannotBeZero();
        HCA_FACTORY = hcaFactory;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Upgrades the calling HCA proxy to a concrete implementation.
    /// @dev Must be called directly by the owner recorded for the proxy in the HCA factory.
    /// @param newImplementation The implementation to install in the proxy.
    /// @param data Optional initialization calldata delegated to `newImplementation`.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable {
        address owner = HCA_FACTORY.getAccountOwner(address(this));
        if (owner == address(0))
            revert HCAOwnerNotSet(address(this));
        if (msg.sender != owner)
            revert CallerNotHCAOwner(msg.sender, owner);
        if (newImplementation.code.length == 0) {
            revert HCAImplementationHasNoCode(newImplementation);
        }

        StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = newImplementation;
        emit Upgraded(newImplementation);

        if (data.length > 0) {
            (bool success, bytes memory result) = newImplementation.delegatecall(data);
            if (!success) {
                assembly ("memory-safe") {
                    revert(add(result, 0x20), mload(result))
                }
            }
        }
    }
}
