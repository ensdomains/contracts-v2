// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHCAFactory} from "./interfaces/IHCAFactory.sol";
import {IHCAInitDataParser} from "./interfaces/IHCAInitDataParser.sol";
import {ProxyLib} from "./ProxyLib.sol";

/// @title HCAFactory
/// @notice Factory for deploying Hidden Contract Accounts as deterministic Nexus proxies.
/// @dev HCA-aware protocol calls require EOAs to explicitly select an implementation before lookup
///      succeeds for non-HCA callers.
contract HCAFactory is Ownable, IHCAFactory {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev The current HCA implementation contract selectable by accounts.
    address internal _implementation;

    /// @dev The parser contract that extracts account ownership from HCA initialization data.
    IHCAInitDataParser internal _initDataGenerator;

    /// @dev Maps each deployed HCA proxy address to its owner.
    mapping(address hca => address owner) internal _hcaOwners;

    /// @dev Maps an account to the implementation selected for its deterministic HCA.
    mapping(address account => address implementation) internal _accountImplementations;

    /// @notice The implementation that lets an HCA owner defer the final account upgrade target.
    address public deferredImplementation;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new HCA is deployed.
    /// @param hcaOwner The owner of the newly created account.
    /// @param hca The address of the deployed HCA proxy.
    event AccountCreated(address indexed hcaOwner, address indexed hca);

    /// @notice Emitted when the implementation and init data parser selectable for new HCA proxies change.
    /// @param accountImplementation The implementation contract selectable for newly deployed HCA proxies.
    /// @param initDataGenerator The parser used to extract account ownership from initialization data.
    event NewHCAImplementation(
        address indexed accountImplementation,
        address indexed initDataGenerator
    );

    /// @notice Emitted when the deferred implementation changes.
    /// @param implementation The new deferred implementation address.
    event DeferredImplementationSet(address indexed implementation);

    /// @notice Emitted when an account selects its HCA implementation.
    /// @param account The account selecting the implementation.
    /// @param implementation The selected implementation.
    event AccountImplementationSet(address indexed account, address indexed implementation);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when an account selects an unsupported implementation.
    /// @param implementation The rejected implementation address.
    /// @dev Error selector: `0xbf4480a4`
    error HCAImplementationNotSelectable(address implementation);

    /// @notice Thrown when an account has not explicitly selected an implementation.
    /// @param account The account missing an implementation selection.
    /// @dev Error selector: `0xa97a8217`
    error HCAImplementationNotSet(address account);

    /// @notice Thrown when setting the deferred implementation to the zero address.
    /// @dev Error selector: `0xb74391a3`
    error DeferredImplementationCannotBeZero();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the factory with an implementation, init data parser, and owner.
    /// @param implementation_ The HCA implementation contract to proxy to.
    /// @param initDataGenerator_ The generator used to parse account-specific init data.
    /// @param owner_ The owner of this factory.
    constructor(address implementation_, IHCAInitDataParser initDataGenerator_, address owner_)
        Ownable(owner_)
    {
        _implementation = implementation_;
        _initDataGenerator = initDataGenerator_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Updates the implementation and init data parser selectable for new HCA proxies.
    /// @param implementation The new implementation address.
    /// @param initDataGenerator The new parser used to extract account ownership from initialization data.
    function setImplementation(address implementation, IHCAInitDataParser initDataGenerator)
        external
        onlyOwner
    {
        _implementation = implementation;
        _initDataGenerator = initDataGenerator;
        emit NewHCAImplementation(implementation, address(initDataGenerator));
    }

    /// @notice Updates the deferred implementation selectable by accounts.
    /// @param implementation The new deferred implementation address.
    function setDeferredImplementation(address implementation) external onlyOwner {
        if (implementation == address(0))
            revert DeferredImplementationCannotBeZero();
        deferredImplementation = implementation;
        emit DeferredImplementationSet(implementation);
    }

    /// @notice Selects the implementation used when deploying the sender's deterministic HCA.
    /// @param implementation The implementation to select.
    function setAccountImplementation(address implementation) external {
        _requireSelectableImplementation(implementation);
        _accountImplementations[msg.sender] = implementation;
        emit AccountImplementationSet(msg.sender, implementation);
    }

    /// @notice Deploys a new HCA proxy for the owner encoded in the initialization data, or forwards ETH if already deployed.
    /// @dev The deployment implementation must have been explicitly selected by the encoded owner.
    /// @param initData The initialization data used to initialize the HCA proxy and identify its owner.
    /// @return hca The deployed or existing HCA proxy address.
    function createAccount(bytes calldata initData) external payable returns (address payable hca) {
        address hcaOwner = getOwnerFromHCAInitdata(initData);
        address implementation = _accountImplementationOf(hcaOwner);
        bool alreadyDeployed;
        if (implementation == deferredImplementation) {
            (alreadyDeployed, hca) = ProxyLib.deployProxyWithoutInitialization(
                implementation,
                hcaOwner
            );
        } else {
            (alreadyDeployed, hca) = ProxyLib.deployProxy(implementation, hcaOwner, initData);
        }
        if (!alreadyDeployed) {
            _hcaOwners[hca] = hcaOwner;
            emit AccountCreated(hcaOwner, hca);
        }
    }

    /// @inheritdoc IHCAFactory
    function getImplementation() external view returns (address) {
        return _implementation;
    }

    /// @inheritdoc IHCAFactory
    function getInitDataGenerator() external view returns (IHCAInitDataParser) {
        return _initDataGenerator;
    }

    /// @notice Returns the owner recorded for a deployed HCA proxy.
    /// @dev Reverts for no-code callers that are neither registered HCAs nor accounts with an implementation selection.
    /// @param hca The HCA or caller address to look up.
    /// @return hcaOwner The recorded HCA owner, or zero for opted-in non-HCA accounts.
    function getAccountOwner(address hca) external view returns (address hcaOwner) {
        hcaOwner = _hcaOwners[hca];
        if (
            hcaOwner == address(0) &&
            _accountImplementations[hca] == address(0) &&
            hca.code.length == 0
        ) {
            revert HCAImplementationNotSet(hca);
        }
    }

    /// @inheritdoc IHCAFactory
    function accountImplementationOf(address account)
        external
        view
        returns (address implementation)
    {
        implementation = _accountImplementations[account];
    }

    /// @inheritdoc IHCAFactory
    function computeAccountAddress(address owner) external view returns (address payable) {
        return ProxyLib.predictProxyAddress(owner);
    }

    /// @inheritdoc IHCAFactory
    function getOwnerFromHCAInitdata(bytes calldata initData)
        public
        view
        returns (address hcaOwner)
    {
        hcaOwner = _initDataGenerator.getOwnerFromInitData(initData);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Reverts unless an account has explicitly selected an implementation.
    function _accountImplementationOf(address account)
        internal
        view
        returns (address implementation)
    {
        implementation = _accountImplementations[account];
        if (implementation == address(0))
            revert HCAImplementationNotSet(account);
    }

    /// @dev Reverts unless the implementation is selectable under the current factory configuration.
    function _requireSelectableImplementation(address implementation) internal view {
        if (implementation == _implementation && implementation != address(0))
            return;
        if (implementation == deferredImplementation && implementation != address(0))
            return;
        revert HCAImplementationNotSelectable(implementation);
    }
}
