// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IStandaloneHCAOwner} from "../hca/interfaces/IStandaloneHCAOwner.sol";

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

    /// @dev Error selector: `0x15bd01c5`
    error HCAOwnerUnavailable(address hca);

    /// @dev Error selector: `0xa8f2205f`
    error HCAOwnerMismatch(address account, address hcaOwner);

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

    /// @dev Resolves a verified HCA caller to its owner, then ensures that owner is `account`.
    function _requireHCAForAccount(address account) internal view returns (address hcaOwner) {
        hcaOwner = _hcaOwner();
        if (hcaOwner != account) {
            revert HCAOwnerMismatch(account, hcaOwner);
        }
    }

    /// @dev Returns the owner of a verified HCA caller with a trusted implementation.
    function _hcaOwner() internal view returns (address) {
        address hcaImplementation = VERIFIABLE_FACTORY.verifyContract(msg.sender);
        if (!trustedHCAImplementations[hcaImplementation]) {
            revert HCAImplementationNotTrusted(hcaImplementation);
        }
        try IStandaloneHCAOwner(msg.sender).owner() returns (address hcaOwner) {
            if (hcaOwner != address(0)) {
                return hcaOwner;
            }
        } catch {}
        revert HCAOwnerUnavailable(msg.sender);
    }
}
