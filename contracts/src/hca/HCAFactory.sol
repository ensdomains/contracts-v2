// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHCAFactory} from "./interfaces/IHCAFactory.sol";
import {ProxyLib} from "./ProxyLib.sol";

/// @notice Minimal account surface used to verify a designated HCA implementation.
/// @dev Interface selector: `0xaaf10f42`
interface IHCAImplementationProvider {
    /// @notice Returns the current implementation for the account.
    function getImplementation() external view returns (address);
}

/// @title HCAFactory
/// @notice Factory for deploying and designating Hardware Contract Accounts (HCAs).
/// @dev Uses CREATE3 via ProxyLib to deploy deterministic NexusProxy instances and records
///      existing approved SCAs when users designate them as HCAs.
contract HCAFactory is Ownable, IHCAFactory {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev The current HCA implementation contract used as the approved upgrade target.
    address internal _implementation;

    /// @dev Maps each deployed HCA proxy address to its owner.
    mapping(address hca => address owner) internal _hcaOwners;

    /// @notice Returns whether an implementation is approved for HCA deployment and upgrades.
    mapping(address implementation => bool approved) public approvedImplementations;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when a new HCA is deployed.
    /// @param hcaOwner The owner of the newly created account.
    /// @param hca The address of the deployed HCA proxy.
    /// @param implementation The implementation used by the deployed HCA proxy.
    event AccountCreated(
        address indexed hcaOwner,
        address indexed hca,
        address indexed implementation
    );

    /// @notice Emitted when an existing SCA is designated as an HCA.
    /// @param hcaOwner The owner that designated the account.
    /// @param hca The address of the designated HCA.
    /// @param implementation The approved implementation used by the HCA.
    event AccountDesignated(
        address indexed hcaOwner,
        address indexed hca,
        address indexed implementation
    );

    /// @notice Emitted when the implementation used as the HCA upgrade target changes.
    /// @param accountImplementation The implementation contract accepted by HCA upgrade guards.
    event NewHCAImplementation(address indexed accountImplementation);

    /// @notice Emitted when an HCA implementation approval changes.
    /// @param accountImplementation The implementation whose approval changed.
    /// @param approved Whether the implementation is approved.
    event HCAImplementationApprovalChanged(
        address indexed accountImplementation,
        bool indexed approved
    );

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when an HCA implementation address is zero.
    /// @dev Error selector: `0x30eb1e65`
    error HCAImplementationCannotBeZero();

    /// @notice Thrown when an HCA implementation is not approved.
    /// @param implementation The implementation that is not approved.
    /// @dev Error selector: `0x1a127e84`
    error HCAImplementationNotApproved(address implementation);

    /// @notice Thrown when revoking the active HCA upgrade implementation.
    /// @param implementation The active implementation that cannot be revoked.
    /// @dev Error selector: `0x8be8f94d`
    error CannotRevokeCurrentHCAImplementation(address implementation);

    /// @notice Thrown when an HCA account address is zero.
    /// @dev Error selector: `0xfc7354e5`
    error HCAAccountCannotBeZero();

    /// @notice Thrown when an HCA account address has no code.
    /// @param hca The account address with no code.
    /// @dev Error selector: `0xed080fb2`
    error HCAAccountHasNoCode(address hca);

    /// @notice Thrown when an HCA account has already been designated.
    /// @param hca The already-designated HCA account.
    /// @param hcaOwner The owner currently recorded for the account.
    /// @dev Error selector: `0x4249bae4`
    error HCAAccountAlreadyDesignated(address hca, address hcaOwner);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the factory with its owner.
    /// @param owner_ The owner of this factory (receives `onlyOwner` privileges).
    constructor(address owner_) Ownable(owner_) {}

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Updates the implementation accepted by HCA upgrade guards.
    /// @param implementation The approved implementation address.
    function setImplementation(address implementation) external onlyOwner {
        _requireApprovedImplementation(implementation);
        _implementation = implementation;
        emit NewHCAImplementation(implementation);
    }

    /// @notice Sets whether an implementation may be used for HCA deployment and upgrades.
    /// @param implementation The implementation address to update.
    /// @param approved Whether the implementation is approved.
    function setImplementationApproval(address implementation, bool approved) external onlyOwner {
        if (implementation == address(0)) revert HCAImplementationCannotBeZero();
        if (!approved && implementation == _implementation) {
            revert CannotRevokeCurrentHCAImplementation(implementation);
        }
        approvedImplementations[implementation] = approved;
        emit HCAImplementationApprovalChanged(implementation, approved);
    }

    /// @notice Deploys a new HCA proxy for the caller, or forwards ETH if already deployed.
    /// @dev The proxy address is deterministic based on `msg.sender`. If the account already
    ///      exists, any attached ETH is forwarded to the existing account.
    /// @param implementation The approved implementation for the HCA proxy.
    /// @param initData The initialization data used to initialize the HCA proxy.
    /// @return hca The deployed or existing HCA proxy address.
    function createAccount(
        address implementation,
        bytes calldata initData
    ) external payable returns (address payable hca) {
        _requireApprovedImplementation(implementation);
        address hcaOwner = msg.sender;
        bool alreadyDeployed;
        (alreadyDeployed, hca) = ProxyLib.deployProxy(implementation, hcaOwner, initData);
        if (!alreadyDeployed) {
            _recordAccountOwner(hcaOwner, hca);
            emit AccountCreated(hcaOwner, hca, implementation);
        }
    }

    /// @notice Designates an existing SCA as the caller's HCA.
    /// @dev The account must already be deployed and use an approved implementation.
    /// @param hca The existing SCA to designate as the caller's HCA.
    function setAccount(address hca) external {
        address implementation = _designateAccount(msg.sender, hca);
        emit AccountDesignated(msg.sender, hca, implementation);
    }

    /// @inheritdoc IHCAFactory
    function getImplementation() external view returns (address) {
        return _implementation;
    }

    /// @inheritdoc IHCAFactory
    function getAccountOwner(address hca) external view returns (address hcaOwner) {
        hcaOwner = _hcaOwners[hca];
    }

    /// @notice Computes the deterministic address of an HCA proxy for the given owner.
    /// @param owner_ The owner whose HCA address to predict.
    /// @return The deterministic proxy address.
    function computeAccountAddress(address owner_) external view returns (address) {
        return ProxyLib.predictProxyAddress(owner_);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Records the account owner after validating account code and implementation approval.
    /// @param hcaOwner The owner to record for the account.
    /// @param hca The account to designate.
    /// @return implementation The account implementation that was validated.
    function _designateAccount(
        address hcaOwner,
        address hca
    ) internal returns (address implementation) {
        _recordAccountOwner(hcaOwner, hca);
        implementation = IHCAImplementationProvider(hca).getImplementation();
        _requireApprovedImplementation(implementation);
    }

    /// @dev Records the account owner after validating account code and uniqueness.
    /// @param hcaOwner The owner to record for the account.
    /// @param hca The account to record.
    function _recordAccountOwner(address hcaOwner, address hca) internal {
        if (hca == address(0)) revert HCAAccountCannotBeZero();
        if (hca.code.length == 0) revert HCAAccountHasNoCode(hca);
        address currentOwner = _hcaOwners[hca];
        if (currentOwner != address(0)) {
            revert HCAAccountAlreadyDesignated(hca, currentOwner);
        }
        _hcaOwners[hca] = hcaOwner;
    }

    /// @dev Reverts unless the implementation is approved for HCA use.
    /// @param implementation The implementation address to check.
    function _requireApprovedImplementation(address implementation) internal view {
        if (!approvedImplementations[implementation]) {
            revert HCAImplementationNotApproved(implementation);
        }
    }
}
