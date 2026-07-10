// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {
    IDefaultReverseRegistrar
} from "@ens/contracts/reverseRegistrar/IDefaultReverseRegistrar.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";
import {HCAContext} from "../utils/HCAContext.sol";
import {IAddressSet} from "../utils/interfaces/IAddressSet.sol";

import {IContractNamer} from "./interfaces/IContractNamer.sol";
import {AccountNamerLib} from "./libraries/AccountNamerLib.sol";

/// @title Default Reverse Registrar Adapter
/// @notice Forwarder for v1 `default.reverse` registrar updates.
/// @dev The adapter must be configured as a controller on the default reverse registrar.
contract DefaultReverseRegistrarAdapter is HCAContext, DelegatedContractNamer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The v1 default reverse registrar for `default.reverse`.
    IDefaultReverseRegistrar public immutable DEFAULT_REVERSE_REGISTRAR;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param defaultReverseRegistrar The v1 default reverse registrar for `default.reverse`.
    /// @param verifiableFactory Shared factory for verifiable deployments.
    /// @param trustedHCASet Set of trusted HCA implementations.
    /// @param contractNamer Delegated contract namer.
    constructor(
        IDefaultReverseRegistrar defaultReverseRegistrar,
        IVerifiableFactory verifiableFactory,
        IAddressSet trustedHCASet,
        IContractNamer contractNamer
    )
        DelegatedContractNamer(contractNamer)
        HCAContext(verifiableFactory, trustedHCASet)
    {
        DEFAULT_REVERSE_REGISTRAR = defaultReverseRegistrar;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Set account's `default.reverse` primary name.
    /// @param account The contract address.
    /// @param name The primary name to store.
    function setName(address account, string calldata name) external {
        AccountNamerLib.requireNamer(account, _unwrapSender());
        DEFAULT_REVERSE_REGISTRAR.setNameForAddr(account, name);
    }
}
