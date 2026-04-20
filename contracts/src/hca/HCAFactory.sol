// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHCA} from "./IHCA.sol";
import {IHCAFactory} from "./IHCAFactory.sol";
import {IInitDataGenerator} from "./IInitDataGenerator.sol";
import {ProxyLib} from "./ProxyLib.sol";

/// @notice Factory for deterministic HCA account deployment.
contract HCAFactory is Ownable, IHCAFactory {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Current HCA implementation used for new proxy deployments.
    address internal _implementation;

    /// @dev Generator used to build owner-specific account initialization data.
    IInitDataGenerator internal _initDataGenerator;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new HCA account is deployed.
    /// @param owner The owner used to derive and initialize the account.
    /// @param account The deployed account address.
    event AccountCreated(address indexed owner, address indexed account);

    /// @notice Emitted when the initialization data generator is updated.
    /// @param generator The new initialization data generator.
    event InitDataGeneratorUpdated(address indexed generator);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Creates the factory with an initial implementation and data generator.
    /// @param implementation_ The implementation used for new accounts.
    /// @param initDataGenerator_ The generator used to build account initialization data.
    /// @param owner_ The owner of the factory.
    constructor(address implementation_, IInitDataGenerator initDataGenerator_, address owner_)
        Ownable(owner_)
    {
        _implementation = implementation_;
        _initDataGenerator = initDataGenerator_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Updates the implementation used for new account deployments.
    /// @param implementation_ The new implementation address.
    function setImplementation(address implementation_) external onlyOwner {
        _implementation = implementation_;
    }

    /// @notice Updates the generator used to build account initialization data.
    /// @param initDataGenerator_ The new initialization data generator.
    function setInitDataGenerator(IInitDataGenerator initDataGenerator_) external onlyOwner {
        _initDataGenerator = initDataGenerator_;
        emit InitDataGeneratorUpdated(address(initDataGenerator_));
    }

    /// @notice Deploys or returns the deterministic HCA account for an owner.
    /// @param owner_ The owner used to derive and initialize the account.
    /// @return The account address.
    function createAccount(address owner_) external returns (address) {
        // Generate account-specific init data using the external generator
        bytes memory accountInitData = _initDataGenerator.generateInitData(owner_);
        (bool alreadyDeployed, address payable account) =
            ProxyLib.deployProxy(_implementation, owner_, accountInitData);
        if (!alreadyDeployed)
            emit AccountCreated(owner_, account);
        return account;
    }

    /// @notice Returns the current account implementation.
    function getImplementation() external view returns (address) {
        return _implementation;
    }

    /// @notice Returns the current initialization data generator.
    function getInitDataGenerator() external view returns (IInitDataGenerator) {
        return _initDataGenerator;
    }

    /// @notice Returns the owner for an HCA account, or zero if it cannot be read.
    /// @param account The account to inspect.
    /// @return The account owner, or zero for non-contracts and incompatible accounts.
    function getAccountOwner(address account) external view returns (address) {
        // Check if the account has code (is a contract)
        if (account.code.length == 0) {
            return address(0);
        }

        try IHCA(account).getOwner() returns (address owner) {
            return owner;
        } catch {
            return address(0);
        }
    }

    /// @notice Computes the deterministic account address for an owner.
    /// @param owner_ The owner used to derive the account address.
    /// @return The predicted account address.
    function computeAccountAddress(address owner_) external view returns (address) {
        return ProxyLib.predictProxyAddress(owner_);
    }
}
