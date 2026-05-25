// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {HCADeferredImplementation} from "./HCADeferredImplementation.sol";
import {IHCAFactory} from "./interfaces/IHCAFactory.sol";
import {IHCAFactoryBasic} from "./interfaces/IHCAFactoryBasic.sol";
import {IHCAInitDataParser} from "./interfaces/IHCAInitDataParser.sol";
import {ProxyLib} from "./ProxyLib.sol";

/// @title HCAFactory
/// @notice Factory for deploying Hidden Contract Accounts as deterministic ERC-1967 proxies.
/// @dev HCA-aware protocol calls resolve deployed HCAs after the deterministic account is recorded
///      for its owner.
contract HCAFactory is Ownable, IHCAFactory {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The implementation that lets an HCA owner defer the final account upgrade target.
    address public immutable DEFERRED_IMPLEMENTATION;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice The current HCA implementation contract selectable by accounts.
    address public implementation;

    /// @notice The parser contract that extracts account ownership from HCA initialization data.
    IHCAInitDataParser public initDataParser;

    /// @dev Maps each deployed HCA proxy address to its owner.
    mapping(address hca => address owner) internal _hcaOwners;

    /// @dev Maps an account to the implementation selected for its deterministic HCA.
    mapping(address account => address implementation) internal _accountImplementations;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new HCA is deployed.
    /// @param hcaOwner The owner of the newly created account.
    /// @param hca The address of the deployed HCA proxy.
    event AccountCreated(address indexed hcaOwner, address indexed hca);

    /// @notice Emitted when the implementation and init data parser selectable for new HCA proxies change.
    /// @param accountImplementation The implementation contract selectable for newly deployed HCA proxies.
    /// @param initDataParser The parser used to extract account ownership from initialization data.
    event NewHCAImplementation(
        address indexed accountImplementation,
        address indexed initDataParser
    );

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

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the factory with an implementation, init data parser, owner, and deferred implementation.
    /// @param implementation_ The HCA implementation contract to proxy to.
    /// @param initDataParser_ The parser used to parse account-specific init data.
    /// @param owner_ The owner of this factory.
    constructor(address implementation_, IHCAInitDataParser initDataParser_, address owner_)
        Ownable(owner_)
    {
        implementation = implementation_;
        initDataParser = initDataParser_;
        DEFERRED_IMPLEMENTATION = address(
            new HCADeferredImplementation(IHCAFactoryBasic(address(this)))
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Updates the implementation and init data parser selectable for new HCA proxies.
    /// @param implementation_ The new implementation address.
    /// @param initDataParser_ The new parser used to extract account ownership from initialization data.
    function setImplementation(address implementation_, IHCAInitDataParser initDataParser_)
        external
        onlyOwner
    {
        implementation = implementation_;
        initDataParser = initDataParser_;
        emit NewHCAImplementation(implementation_, address(initDataParser_));
    }

    /// @notice Selects the implementation used when deploying the sender's deterministic HCA.
    /// @param accountImplementation The implementation to select.
    function setAccountImplementation(address accountImplementation) external {
        _requireSelectableImplementation(accountImplementation);
        _accountImplementations[msg.sender] = accountImplementation;
        emit AccountImplementationSet(msg.sender, accountImplementation);
    }

    /// @notice Deploys a new HCA proxy for the owner encoded in the initialization data, or forwards ETH if already deployed.
    /// @dev Uses the owner's selected implementation when set, otherwise the current implementation.
    /// @param initData The initialization data used to initialize the HCA proxy and identify its owner.
    /// @return hca The deployed or existing HCA proxy address.
    function createAccount(bytes calldata initData) external payable returns (address payable hca) {
        address hcaOwner = getOwnerFromHCAInitdata(initData);
        address accountImplementation = _deploymentImplementationOf(hcaOwner);
        bool alreadyDeployed;
        if (accountImplementation == DEFERRED_IMPLEMENTATION) {
            (alreadyDeployed, hca) = ProxyLib.deployProxyWithoutInitialization(
                accountImplementation,
                hcaOwner
            );
        } else {
            (alreadyDeployed, hca) = ProxyLib.deployProxy(accountImplementation, hcaOwner, initData);
        }
        if (!alreadyDeployed) {
            _hcaOwners[hca] = hcaOwner;
            emit AccountCreated(hcaOwner, hca);
        }
    }

    /// @notice Returns the owner recorded for a deployed HCA proxy.
    /// @dev Returns zero for non-HCA callers and for HCAs that are not recorded for their owner.
    /// @param hca The HCA or caller address to look up.
    /// @return hcaOwner The recorded HCA owner, or zero when the caller has no recorded HCA mapping.
    function getAccountOwner(address hca) external view returns (address hcaOwner) {
        hcaOwner = _hcaOwners[hca];
        if (hcaOwner == address(0) || ProxyLib.predictProxyAddress(hcaOwner) != hca) {
            return address(0);
        }
    }

    /// @inheritdoc IHCAFactory
    function accountHCAOf(address account) external view returns (address hca) {
        if (account == address(0)) {
            return address(0);
        }
        hca = ProxyLib.predictProxyAddress(account);
        if (_hcaOwners[hca] != account) {
            return address(0);
        }
    }

    /// @inheritdoc IHCAFactory
    function accountImplementationOf(address account)
        external
        view
        returns (address accountImplementation)
    {
        accountImplementation = _accountImplementations[account];
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
        hcaOwner = initDataParser.getOwnerFromInitData(initData);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns an account's selected implementation, or the current implementation when unset.
    function _deploymentImplementationOf(address account)
        internal
        view
        returns (address accountImplementation)
    {
        accountImplementation = _accountImplementations[account];
        if (accountImplementation == address(0)) {
            accountImplementation = implementation;
        }
    }

    /// @dev Reverts unless the implementation is selectable by this factory.
    function _requireSelectableImplementation(address accountImplementation) internal view {
        if (accountImplementation == implementation && accountImplementation != address(0)) {
            return;
        }
        if (accountImplementation == DEFERRED_IMPLEMENTATION && accountImplementation != address(0)) {
            return;
        }
        revert HCAImplementationNotSelectable(accountImplementation);
    }
}
