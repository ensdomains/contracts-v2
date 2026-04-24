// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHCAFactory} from "./interfaces/IHCAFactory.sol";
import {IHCAInitDataParser} from "./interfaces/IHCAInitDataParser.sol";
import {ProxyLib} from "./ProxyLib.sol";

/// @notice Factory for deploying deterministic Hardware Contract Account proxies.
/// @dev Uses owner-derived CREATE3 salts and records the owner for accounts created by this factory.
contract HCAFactory is Ownable, IHCAFactory {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Current HCA implementation used by new proxy deployments.
    address internal _implementation;

    /// @dev Parser used to read account owners from initialization data.
    IHCAInitDataParser internal _initDataGenerator;

    /// @dev Owner recorded for each account deployed by this factory.
    mapping(address hca => address owner) internal _hcaOwners;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new HCA is deployed.
    /// @param hcaOwner The owner of the newly created account.
    /// @param hca The address of the deployed HCA proxy.
    event AccountCreated(address indexed hcaOwner, address indexed hca);

    /// @notice Emitted when the account implementation and init data parser are updated.
    /// @param accountImplementation The implementation used by new HCA proxies.
    /// @param initDataGenerator The parser used to read owners from initialization data.
    event NewHCAImplementation(
        address indexed accountImplementation,
        address indexed initDataGenerator
    );

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Creates the factory with an initial implementation and init data parser.
    /// @param implementation_ The implementation used by new HCA proxies.
    /// @param initDataGenerator_ The parser used to read owners from initialization data.
    /// @param owner_ The owner of the factory.
    constructor(address implementation_, IHCAInitDataParser initDataGenerator_, address owner_)
        Ownable(owner_)
    {
        _implementation = implementation_;
        _initDataGenerator = initDataGenerator_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Updates the implementation and parser used for new account deployments.
    /// @param implementation_ The new implementation address.
    /// @param initDataGenerator_ The new init data parser.
    function setImplementation(address implementation_, IHCAInitDataParser initDataGenerator_)
        external
        onlyOwner
    {
        _implementation = implementation_;
        _initDataGenerator = initDataGenerator_;
        emit NewHCAImplementation(implementation_, address(initDataGenerator_));
    }

    /// @notice Deploys or returns the deterministic HCA account for initialization data.
    /// @dev If the account already exists, any attached ETH is forwarded to the existing account.
    /// @param initData The account initialization data.
    /// @return hca The account address.
    function createAccount(bytes calldata initData) external payable returns (address payable hca) {
        address hcaOwner = getOwnerFromHCAInitdata(initData);
        bool alreadyDeployed;
        (alreadyDeployed, hca) = ProxyLib.deployProxy(_implementation, hcaOwner, initData);
        if (!alreadyDeployed) {
            emit AccountCreated(hcaOwner, hca);
            _hcaOwners[hca] = hcaOwner;
        }
    }

    /// @notice Returns the current account implementation.
    function getImplementation() external view returns (address) {
        return _implementation;
    }

    /// @notice Returns the current init data parser.
    function getInitDataGenerator() external view returns (IHCAInitDataParser) {
        return _initDataGenerator;
    }

    /// @notice Returns the owner of an account deployed by this factory.
    /// @param hca The HCA proxy address to inspect.
    /// @return hcaOwner The recorded owner, or zero if the account was not deployed by this factory.
    function getAccountOwner(address hca) external view returns (address hcaOwner) {
        hcaOwner = _hcaOwners[hca];
    }

    /// @notice Computes the deterministic account address for an owner.
    /// @param owner_ The owner used to derive the account address.
    /// @return The predicted account address.
    function computeAccountAddress(address owner_) external view returns (address) {
        return ProxyLib.predictProxyAddress(owner_);
    }

    /// @notice Returns the HCA owner encoded in initialization data.
    /// @param initData The account initialization data.
    /// @return hcaOwner The owner parsed from the initialization data.
    function getOwnerFromHCAInitdata(bytes calldata initData)
        public
        view
        returns (address hcaOwner)
    {
        hcaOwner = _initDataGenerator.getOwnerFromInitData(initData);
    }
}
