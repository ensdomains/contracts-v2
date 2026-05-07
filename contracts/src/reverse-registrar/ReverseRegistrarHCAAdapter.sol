// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IReverseRegistrar} from "@ens/contracts/reverseRegistrar/IReverseRegistrar.sol";

import {HCAContext} from "../hca/HCAContext.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

/// @title Reverse Registrar HCA Adapter
/// @notice HCA-aware forwarder for v1 `addr.reverse` registrar updates.
/// @dev The adapter must be configured as a controller on the reverse registrar.
contract ReverseRegistrarHCAAdapter is HCAContext {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The v1 reverse registrar for `addr.reverse`.
    IReverseRegistrar public immutable REVERSE_REGISTRAR;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the adapter with its HCA context and target registrar.
    /// @param hcaFactory The HCA factory used to resolve HCA callers to their owners.
    /// @param reverseRegistrar The v1 reverse registrar for `addr.reverse`.
    constructor(
        IHCAFactoryBasic hcaFactory,
        IReverseRegistrar reverseRegistrar
    ) HCAEquivalence(hcaFactory) {
        REVERSE_REGISTRAR = reverseRegistrar;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Claims the caller's `addr.reverse` node and sets its resolver.
    /// @dev The resolved HCA owner is used as both the reverse address and node owner.
    /// @param resolver The resolver to set on the caller's reverse node.
    /// @return node The ENS node hash for the caller's reverse record.
    function claimForAddr(address resolver) external returns (bytes32 node) {
        address sender = _msgSender();
        node = REVERSE_REGISTRAR.claimForAddr(sender, sender, resolver);
    }
}
