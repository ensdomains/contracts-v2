// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {IStandaloneHCAOwner} from "../hca/interfaces/IStandaloneHCAOwner.sol";
import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";

/// @dev Authorizes an account through a VerifiableFactory-verified HCA caller.
abstract contract HCAAuthorizer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The VerifiableFactory used to verify HCA callers.
    IVerifiableFactory public immutable VERIFIABLE_FACTORY;

    /// @notice The list of trusted implementations.
    IAddressSet public immutable TRUSTED_HCA_SET;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0x11001e7e`
    error HCAImplementationNotTrusted(address hcaImplementation);

    /// @dev Error selector: `0x15bd01c5`
    error HCAOwnerUnavailable(address hca);

    /// @dev Error selector: `0xa8f2205f`
    error HCAOwnerMismatch(address account, address hcaOwner);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param verifiableFactory Shared factory for verifiable deployments.
    /// @param trustedHCASet Set of trusted HCA implementations.
    constructor(IVerifiableFactory verifiableFactory, IAddressSet trustedHCASet) {
        VERIFIABLE_FACTORY = verifiableFactory;
        TRUSTED_HCA_SET = trustedHCASet;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

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
        if (!TRUSTED_HCA_SET.includes(hcaImplementation)) {
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
