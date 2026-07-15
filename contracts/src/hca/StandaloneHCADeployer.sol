// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

import {StandaloneSingleOwnerHCA} from "./StandaloneSingleOwnerHCA.sol";

/// @title Standalone HCA Deployer
/// @notice Deploys owner-bound standalone HCAs through a fixed VerifiableFactory.
/// @dev The resulting proxy address is determined by this deployer, `userSalt`, `owner`, and
///      `hcaImplementation`. Any caller may deploy an account, but cannot substitute an
///      implementation at the address expected for another implementation.
contract StandaloneHCADeployer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The factory used for every HCA deployment.
    IVerifiableFactory public immutable VERIFIABLE_FACTORY;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0xbc0ff6a0`
    error VerifiableFactoryCannotBeZero();

    /// @dev Error selector: `0x30eb1e65`
    error HCAImplementationCannotBeZero();

    /// @dev Error selector: `0x9b15e16f`
    error OwnerCannotBeZero();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param verifiableFactory The factory used for every HCA deployment.
    constructor(IVerifiableFactory verifiableFactory) {
        if (address(verifiableFactory) == address(0)) {
            revert VerifiableFactoryCannotBeZero();
        }
        VERIFIABLE_FACTORY = verifiableFactory;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Deploys and initializes an HCA for `owner`.
    /// @dev The external caller does not affect the proxy address because this contract is always
    ///      the caller observed by VerifiableFactory.
    /// @param owner The immutable owner of the deployed HCA.
    /// @param hcaImplementation The initial HCA implementation.
    /// @param userSalt An optional namespace or account-version salt.
    /// @return hca The deployed HCA proxy.
    function deploy(address owner, address hcaImplementation, uint256 userSalt)
        external
        returns (address hca)
    {
        if (owner == address(0)) {
            revert OwnerCannotBeZero();
        }
        if (hcaImplementation == address(0)) {
            revert HCAImplementationCannotBeZero();
        }

        bytes memory initData =
            abi.encodeCall(StandaloneSingleOwnerHCA.initializeAccount, (abi.encode(owner)));
        hca = VERIFIABLE_FACTORY.deployProxy(
            hcaImplementation,
            deploymentSalt(owner, hcaImplementation, userSalt),
            initData
        );
    }

    /// @notice Derives the VerifiableFactory salt for an owner, implementation, and user salt.
    /// @param owner The immutable owner of the deployed HCA.
    /// @param hcaImplementation The initial HCA implementation.
    /// @param userSalt An optional namespace or account-version salt.
    /// @return The owner- and implementation-bound salt supplied to VerifiableFactory.
    function deploymentSalt(address owner, address hcaImplementation, uint256 userSalt)
        public
        pure
        returns (uint256)
    {
        return uint256(keccak256(abi.encode(userSalt, owner, hcaImplementation)));
    }
}
