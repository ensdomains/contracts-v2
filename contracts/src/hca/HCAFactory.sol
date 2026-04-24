// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHCAFactory} from "./interfaces/IHCAFactory.sol";
import {IHCAInitDataParser} from "./interfaces/IHCAInitDataParser.sol";
import {ProxyLib} from "./ProxyLib.sol";

/// @title HCAFactory
/// @notice Factory for deploying Hardware Contract Accounts (HCAs) as deterministic proxies.
/// @dev Uses CREATE3 via ProxyLib to deploy NexusProxy instances at addresses derived from the owner.
///      An external IHCAInitDataParser provides account-specific initialization data at deploy time.
contract HCAFactory is Ownable, IHCAFactory {
    /// @notice The current HCA implementation contract that new proxies delegate to.
    address internal _implementation;
    /// @notice The generator contract that produces account-specific initialization data.
    IHCAInitDataParser internal _initDataGenerator;

    /// @notice Maps each deployed HCA proxy address to its owner.
    mapping(address hca => address owner) internal _hcaOwners;

    /// @notice Emitted when a new HCA is deployed.
    /// @param hcaOwner The owner of the newly created account.
    /// @param hca The address of the deployed HCA proxy.
    event AccountCreated(address indexed hcaOwner, address indexed hca);

    event NewHCAImplementation(
        address indexed accountImplementation,
        address indexed initDataGenerator
    );

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the factory with an implementation, init data generator, and owner.
    /// @param implementation_ The HCA implementation contract to proxy to.
    /// @param initDataGenerator_ The generator used to produce account-specific init data.
    /// @param owner_ The owner of this factory (receives `onlyOwner` privileges).
    constructor(address implementation_, IHCAInitDataParser initDataGenerator_, address owner_)
        Ownable(owner_)
    {
        _implementation = implementation_;
        _initDataGenerator = initDataGenerator_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Updates the HCA implementation contract that new proxies will point to.
    /// @param implementation_ The new implementation address.
    function setImplementation(address implementation_, IHCAInitDataParser initDataGenerator_)
        external
        onlyOwner
    {
        _implementation = implementation_;
        _initDataGenerator = initDataGenerator_;
        emit NewHCAImplementation(implementation_, address(initDataGenerator_));
    }

    /// @notice Deploys a new HCA proxy for the given owner, or forwards ETH if already deployed.
    /// @dev The proxy address is deterministic based on `hcaOwner_`. If the account already exists,
    ///      any attached ETH is forwarded to the existing account.
    function createAccount(bytes calldata initData) external payable returns (address payable hca) {
        // Generate account-specific init data using the external generator
        address hcaOwner_ = getOwnerFromHCAInitdata(initData);
        bool alreadyDeployed;
        (alreadyDeployed, hca) = ProxyLib.deployProxy(_implementation, hcaOwner_, initData);
        if (!alreadyDeployed) {
            emit AccountCreated(hcaOwner_, hca);
            _hcaOwners[hca] = hcaOwner_;
        }
    }

    /// @notice Returns the current HCA implementation address.
    function getImplementation() external view returns (address) {
        return _implementation;
    }

    /// @notice Returns the current init data generator.
    function getInitDataGenerator() external view returns (IHCAInitDataParser) {
        return _initDataGenerator;
    }

    /// @notice Returns the owner of a deployed HCA proxy.
    /// @param hca The HCA proxy address to look up.
    /// @return hcaOwner The owner address, or `address(0)` if the HCA was not deployed by this factory.
    function getAccountOwner(address hca) external view returns (address hcaOwner) {
        hcaOwner = _hcaOwners[hca];
    }

    /// @notice Computes the deterministic address of an HCA proxy for the given owner.
    /// @param owner_ The owner whose HCA address to predict.
    /// @return The deterministic proxy address.
    function computeAccountAddress(address owner_) external view returns (address) {
        return ProxyLib.predictProxyAddress(owner_);
    }

    function getOwnerFromHCAInitdata(bytes calldata initData)
        public
        view
        returns (address hcaOwner)
    {
        hcaOwner = _initDataGenerator.getOwnerFromInitData(initData);
    }
}
