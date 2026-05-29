// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IERC1967} from "@openzeppelin/contracts/interfaces/IERC1967.sol";
import {StorageSlot} from "@openzeppelin/contracts/utils/StorageSlot.sol";

import {IHCAFactoryBasic} from "./interfaces/IHCAFactoryBasic.sol";

/// @title HCADeferredImplementation
/// @notice Minimal implementation for HCAs whose owner has deferred the final account implementation.
/// @dev Calls are expected to arrive through an ERC-1967 proxy registered in the HCA factory.
contract HCADeferredImplementation is IERC1967 {
    ////////////////////////////////////////////////////////////////////////
    // Constants & Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @dev ERC-1967 implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @notice The HCA factory used to authorize owner upgrades.
    IHCAFactoryBasic public immutable HCA_FACTORY;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when the HCA factory is the zero address.
    /// @dev Error selector: `0x841d6202`
    error HCAFactoryCannotBeZero();

    /// @notice Thrown when a caller is not the registered HCA owner.
    /// @param caller The unauthorized caller.
    /// @param owner The registered HCA owner.
    /// @dev Error selector: `0x633d83ce`
    error HCADeferredUpgradeUnauthorized(address caller, address owner);

    /// @notice Thrown when the HCA factory has no owner registered for the proxy.
    /// @dev Error selector: `0xd815aa7d`
    error HCADeferredOwnerNotSet();

    /// @notice Thrown when the target implementation has no contract code.
    /// @param implementation The rejected implementation address.
    /// @dev Error selector: `0x1e122895`
    error HCADeferredImplementationHasNoCode(address implementation);

    /// @notice Thrown when the post-upgrade delegatecall fails.
    /// @dev Error selector: `0x107fd274`
    error HCADeferredInitializationFailed();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param hcaFactory The HCA factory used for ownership lookup.
    constructor(IHCAFactoryBasic hcaFactory) {
        if (address(hcaFactory) == address(0))
            revert HCAFactoryCannotBeZero();
        HCA_FACTORY = hcaFactory;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Upgrades the proxy to a final implementation and optionally initializes it.
    /// @param newImplementation The implementation to install in the proxy.
    /// @param data Optional initialization call data delegated to the new implementation.
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable {
        address owner = HCA_FACTORY.getAccountOwner(address(this));
        if (owner == address(0))
            revert HCADeferredOwnerNotSet();
        if (msg.sender != owner)
            revert HCADeferredUpgradeUnauthorized(msg.sender, owner);
        if (newImplementation.code.length == 0)
            revert HCADeferredImplementationHasNoCode(newImplementation);

        StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = newImplementation;
        emit Upgraded(newImplementation);

        if (data.length == 0)
            return;

        (bool success, ) = newImplementation.delegatecall(data);
        if (!success)
            revert HCADeferredInitializationFailed();
    }
}
