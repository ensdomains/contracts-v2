// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {
    IDefaultReverseRegistrar
} from "@ens/contracts/reverseRegistrar/IDefaultReverseRegistrar.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {DelegatedContractNamer} from "../utils/DelegatedContractNamer.sol";
import {HCAAuthorizer} from "../utils/HCAAuthorizer.sol";

import {IContractNamer} from "./interfaces/IContractNamer.sol";
import {AccountNamerLib} from "./libraries/AccountNamerLib.sol";

/// @title Default Reverse Registrar Adapter
/// @notice Forwarder for v1 `default.reverse` registrar updates.
/// @dev The adapter must be configured as a controller on the default reverse registrar.
contract DefaultReverseRegistrarAdapter is DelegatedContractNamer, HCAAuthorizer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The v1 default reverse registrar for `default.reverse`.
    IDefaultReverseRegistrar public immutable DEFAULT_REVERSE_REGISTRAR;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param defaultReverseRegistrar The v1 default reverse registrar for `default.reverse`.
    /// @param contractNamer Delegated contract namer.
    /// @param verifiableFactory The VerifiableFactory used to verify HCA callers.
    /// @param owner_ The owner allowed to update trusted HCA implementations.
    /// @param initialTrustedHCAImplementations HCA implementations trusted at deployment.
    constructor(
        IDefaultReverseRegistrar defaultReverseRegistrar,
        IContractNamer contractNamer,
        IVerifiableFactory verifiableFactory,
        address owner_,
        address[] memory initialTrustedHCAImplementations
    )
        DelegatedContractNamer(contractNamer)
        HCAAuthorizer(verifiableFactory, owner_, initialTrustedHCAImplementations)
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
        AccountNamerLib.requireNamer(account, msg.sender);
        DEFAULT_REVERSE_REGISTRAR.setNameForAddr(account, name);
    }

    /// @notice Sets account's `default.reverse` primary name through an HCA caller.
    /// @param account The account to name.
    /// @param name The primary name to store.
    function setNameWithHCA(address account, string calldata name) external {
        _requireHCAForAccount(account);
        DEFAULT_REVERSE_REGISTRAR.setNameForAddr(account, name);
    }
}
