// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHCA} from "./interfaces/IHCA.sol";

/// @dev Authorizes an account through a VerifiableFactory-verified HCA caller.
abstract contract HCAAuthorizer is Ownable {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The VerifiableFactory used to verify HCA callers.
    IVerifiableFactory public immutable VERIFIABLE_FACTORY;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Trusted HCA implementations that may authorize account updates through this adapter.
    mapping(address hcaImplementation => bool trusted) public trustedHCAImplementations;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a trusted HCA implementation is updated.
    /// @param hcaImplementation The VerifiableFactory HCA implementation.
    /// @param trusted Whether the HCA implementation is trusted.
    event TrustedHCAImplementationUpdated(address indexed hcaImplementation, bool trusted);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0xbc0ff6a0`
    error VerifiableFactoryCannotBeZero();

    /// @dev Error selector: `0x30eb1e65`
    error HCAImplementationCannotBeZero();

    /// @dev Error selector: `0x11001e7e`
    error HCAImplementationNotTrusted(address hcaImplementation);

    /// @dev Error selector: `0x0cb76355`
    error HCANotOwner(address hca, address account);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param verifiableFactory The VerifiableFactory used to verify HCA callers.
    /// @param owner_ The owner allowed to update trusted HCA implementations.
    /// @param initialTrustedHCAImplementations HCA implementations trusted at deployment.
    constructor(
        IVerifiableFactory verifiableFactory,
        address owner_,
        address[] memory initialTrustedHCAImplementations
    )
        Ownable(owner_)
    {
        if (address(verifiableFactory) == address(0)) {
            revert VerifiableFactoryCannotBeZero();
        }
        VERIFIABLE_FACTORY = verifiableFactory;

        for (uint256 i; i < initialTrustedHCAImplementations.length; ++i) {
            _setTrustedHCAImplementation(initialTrustedHCAImplementations[i], true);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Updates whether an HCA implementation can authorize account updates.
    /// @param hcaImplementation The VerifiableFactory HCA implementation.
    /// @param trusted Whether the HCA implementation is trusted.
    function setTrustedHCAImplementation(address hcaImplementation, bool trusted)
        external
        onlyOwner
    {
        _setTrustedHCAImplementation(hcaImplementation, trusted);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Updates the trusted HCA implementation mapping.
    function _setTrustedHCAImplementation(address hcaImplementation, bool trusted) internal {
        if (hcaImplementation == address(0)) {
            revert HCAImplementationCannotBeZero();
        }
        trustedHCAImplementations[hcaImplementation] = trusted;
        emit TrustedHCAImplementationUpdated(hcaImplementation, trusted);
    }

    /// @dev Requires the caller to be a trusted HCA that currently owns `account`.
    /// @param account The account the HCA caller must currently own.
    function _requireHCAForAccount(address account) internal view {
        address hcaImplementation = VERIFIABLE_FACTORY.verifyContract(msg.sender);
        if (!trustedHCAImplementations[hcaImplementation]) {
            revert HCAImplementationNotTrusted(hcaImplementation);
        }
        if (!IHCA(msg.sender).isOwner(account)) {
            revert HCANotOwner(msg.sender, account);
        }
    }
}
