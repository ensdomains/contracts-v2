// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

/// @title Standalone Verifiable Factory Interface
/// @notice Minimal VerifiableFactory interface used by the registration bootstrapper.
/// @dev Interface selector: `0x5d84121a`
interface IStandaloneVerifiableFactory {
    /// @notice Deploys a verifiable proxy.
    /// @param implementation The implementation address.
    /// @param salt The deployment salt.
    /// @param data Initialization calldata for the proxy.
    /// @return proxy The deployed proxy address.
    function deployProxy(address implementation, uint256 salt, bytes calldata data)
        external
        returns (address proxy);
}


/// @title Standalone Registration Committer Interface
/// @notice Minimal registrar interface for writing a registration commitment.
/// @dev Interface selector: `0xf14fcbc8`
interface IStandaloneRegistrationCommitter {
    /// @notice Writes a registration commitment.
    /// @param commitment The commitment hash.
    function commit(bytes32 commitment) external;
}


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
        IStandaloneVerifiableFactory verifiableFactory,
        address hcaImplementation,
        uint256 salt,
        bytes calldata initData,
        IStandaloneRegistrationCommitter registrar,
        bytes32 commitment
    )
        external
        returns (address hca)
    {
        hca = verifiableFactory.deployProxy(hcaImplementation, salt, initData);
        registrar.commit(commitment);
    }
}
