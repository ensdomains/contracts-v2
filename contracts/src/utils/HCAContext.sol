// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";

import {IHCA} from "./interfaces/IHCA.sol";

/// @dev Mixin for HCA functionality.
abstract contract HCAContext {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The VerifiableFactory used to verify HCA callers.
    IVerifiableFactory public immutable VERIFIABLE_FACTORY;

    /// @notice The list of trusted implementations.
    IAddressSet public immutable TRUSTED_HCA_SET;

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

    /// @dev Returns HCA owner or `account` if not a trusted HCA.
    function _unwrapAccount(address account) internal view returns (address) {
        try VERIFIABLE_FACTORY.verifyContract(account) returns (address impl) {
            if (TRUSTED_HCA_SET.includes(impl)) {
                return IHCA(account).owner();
            }
        } catch {}
        return account;
    }

    /// @dev Convenience for `_unwrapAccount(msg.sender)`.
    function _unwrapSender() internal view returns (address) {
        return _unwrapAccount(msg.sender);
    }
}
