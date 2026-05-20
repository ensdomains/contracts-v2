// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {
    IDefaultReverseRegistrar
} from "@ens/contracts/reverseRegistrar/IDefaultReverseRegistrar.sol";

import {HCAContext} from "../hca/HCAContext.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";

/// @title Default Reverse Registrar HCA Adapter
/// @notice HCA-aware forwarder for v1 `default.reverse` registrar updates.
/// @dev The adapter must be configured as a controller on the default reverse registrar.
contract DefaultReverseRegistrarHCAAdapter is HCAContext {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The v1 default reverse registrar for `default.reverse`.
    IDefaultReverseRegistrar public immutable DEFAULT_REVERSE_REGISTRAR;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the adapter with its HCA context and target registrar.
    /// @param hcaFactory The HCA factory used to resolve HCA callers to their owners.
    /// @param defaultReverseRegistrar The v1 default reverse registrar for `default.reverse`.
    constructor(IHCAFactoryBasic hcaFactory, IDefaultReverseRegistrar defaultReverseRegistrar)
        HCAEquivalence(hcaFactory)
    {
        DEFAULT_REVERSE_REGISTRAR = defaultReverseRegistrar;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Sets the caller's `default.reverse` primary name.
    /// @dev The resolved HCA owner is used as the address whose name is updated.
    /// @param name The primary name to store.
    function setNameForAddr(string calldata name) external {
        DEFAULT_REVERSE_REGISTRAR.setNameForAddr(_msgSender(), name);
    }
}
