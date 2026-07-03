// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IReverseRegistrar} from "@ens/contracts/reverseRegistrar/IReverseRegistrar.sol";

import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";

import {IContractNamer} from "./interfaces/IContractNamer.sol";
import {AccountNamerLib} from "./libraries/AccountNamerLib.sol";

/// @title Reverse Registrar Adapter
/// @notice Forwarder for v1 `addr.reverse` registrar updates.
/// @dev The adapter must be configured as a controller on the reverse registrar.
contract ReverseRegistrarAdapter is DelegatedContractNamer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The v1 reverse registrar for `addr.reverse`.
    IReverseRegistrar public immutable REVERSE_REGISTRAR;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param reverseRegistrar The v1 reverse registrar for `addr.reverse`.
    /// @param contractNamer Delegated contract namer.
    constructor(IReverseRegistrar reverseRegistrar, IContractNamer contractNamer)
        DelegatedContractNamer(contractNamer)
    {
        REVERSE_REGISTRAR = reverseRegistrar;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Claims account's `addr.reverse` node and sets its resolver.
    /// @param account The account to claim.
    /// @param resolver The resolver to set.
    /// @return The ENS node hash for the contract's reverse record.
    function claim(address account, address resolver) external returns (bytes32) {
        address sender = msg.sender;
        AccountNamerLib.requireNamer(account, sender);
        return REVERSE_REGISTRAR.claimForAddr(account, sender, resolver);
    }
}
