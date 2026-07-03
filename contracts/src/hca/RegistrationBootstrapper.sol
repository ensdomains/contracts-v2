// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {IETHRegistrar} from "../registrar/interfaces/IETHRegistrar.sol";

/// @title Registration Bootstrapper
/// @notice Deploys a standalone HCA and writes a registration commitment in one transaction.
contract RegistrationBootstrapper {
    /// @notice Deploys the HCA proxy and commits the registration secret.
    /// @param verifiableFactory The factory used to deploy the HCA proxy.
    /// @param hcaImplementation The HCA implementation to deploy behind the proxy.
    /// @param salt The verifiable proxy deployment salt.
    /// @param initData Initialization calldata for the HCA proxy.
    /// @param registrar The registrar that stores registration commitments.
    /// @param commitment The commitment hash.
    /// @return hca The deployed HCA proxy address.
    function deployAndCommit(
        IVerifiableFactory verifiableFactory,
        address hcaImplementation,
        uint256 salt,
        bytes calldata initData,
        IETHRegistrar registrar,
        bytes32 commitment
    )
        external
        returns (address hca)
    {
        hca = verifiableFactory.deployProxy(hcaImplementation, salt, initData);
        registrar.commit(commitment);
    }
}
