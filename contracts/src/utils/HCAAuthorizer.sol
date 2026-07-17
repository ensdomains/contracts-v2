// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";

import {IHCA} from "./interfaces/IHCA.sol";

/// @dev Authorizes an account through a VerifiableFactory-verified HCA caller.
abstract contract HCAAuthorizer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Shared factory for verifiable deployments.
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
    function _unwrapHCA(address sender) internal view returns (bool isHCA, address unwrapped) {
        try VERIFIABLE_FACTORY.verifyContract(sender) returns (address impl) {
            if (TRUSTED_HCA_SET.includes(impl)) {
                unwrapped = IHCA(sender).owner();
                if (unwrapped != address(0)) {
                    return (true, unwrapped);
                }
            }
        } catch {}
        return (false, sender);
    }
}
