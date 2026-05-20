// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IHCAFactory} from "./interfaces/IHCAFactory.sol";

/// @title HCAFactory
/// @notice Registry for Hidden Contract Account (HCA) ownership and implementation pins.
/// @dev HCA-aware protocol lookups resolve registered HCAs to owners. If a caller has no
///      registered HCA, the caller must have explicitly pinned an implementation before HCA
///      equivalence is accepted.
contract HCAFactory is Ownable, IHCAFactory {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The factory used to verify designated HCA proxy deployments.
    IVerifiableFactory public immutable VERIFIABLE_FACTORY;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @dev Maps each designated HCA proxy address to its owner.
    mapping(address hca => address owner) internal _hcaOwners;

    /// @dev Tracks implementations approved for HCA designation and future HCA deployment.
    mapping(address implementation => bool approved) internal _approvedImplementations;

    /// @dev Records the implementation a caller explicitly selected for HCA equivalence.
    mapping(address account => address implementation) internal _accountImplementations;

    /// @notice The implementation a caller may explicitly select before a concrete HCA upgrade.
    address public deferredImplementation;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when an existing SCA is designated as an HCA.
    /// @param hcaOwner The owner that designated the account.
    /// @param hca The address of the designated HCA.
    /// @param implementation The approved implementation used by the HCA.
    event AccountDesignated(
        address indexed hcaOwner,
        address indexed hca,
        address indexed implementation
    );

    /// @notice Emitted when an account explicitly pins an HCA implementation.
    /// @param account The account that selected the implementation.
    /// @param implementation The selected HCA implementation.
    event AccountImplementationSet(address indexed account, address indexed implementation);

    /// @notice Emitted when an HCA implementation approval changes.
    /// @param accountImplementation The implementation whose approval changed.
    /// @param approved Whether the implementation is approved.
    event HCAImplementationApprovalChanged(
        address indexed accountImplementation,
        bool indexed approved
    );

    /// @notice Emitted when the deferred HCA implementation changes.
    /// @param implementation The deferred implementation address.
    event DeferredImplementationSet(address indexed implementation);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when the verifiable factory address is zero.
    /// @dev Error selector: `0xbc0ff6a0`
    error VerifiableFactoryCannotBeZero();

    /// @notice Thrown when an HCA implementation address is zero.
    /// @dev Error selector: `0x30eb1e65`
    error HCAImplementationCannotBeZero();

    /// @notice Thrown when an HCA implementation is not approved.
    /// @param implementation The implementation that is not approved.
    /// @dev Error selector: `0x1a127e84`
    error HCAImplementationNotApproved(address implementation);

    /// @notice Thrown when an account has not explicitly selected an HCA implementation.
    /// @param account The account that has no implementation pinned.
    /// @dev Error selector: `0xa97a8217`
    error HCAImplementationNotSet(address account);

    /// @notice Thrown when an HCA account address is zero.
    /// @dev Error selector: `0xfc7354e5`
    error HCAAccountCannotBeZero();

    /// @notice Thrown when an HCA account address has no code.
    /// @param hca The account address with no code.
    /// @dev Error selector: `0xed080fb2`
    error HCAAccountHasNoCode(address hca);

    /// @notice Thrown when an HCA account is not a verified proxy for the expected implementation.
    /// @param hca The account that could not be verified.
    /// @param implementation The expected implementation.
    /// @dev Error selector: `0xcc26dd93`
    error HCAAccountNotVerifiable(address hca, address implementation);

    /// @notice Thrown when an HCA account has already been designated.
    /// @param hca The already-designated HCA account.
    /// @param hcaOwner The owner currently recorded for the account.
    /// @dev Error selector: `0x4249bae4`
    error HCAAccountAlreadyDesignated(address hca, address hcaOwner);

    /// @notice Thrown when the deferred HCA implementation address is zero.
    /// @dev Error selector: `0xb74391a3`
    error DeferredImplementationCannotBeZero();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the factory with its owner.
    /// @param verifiableFactory The factory used to verify designated HCA proxy deployments.
    /// @param owner_ The owner of this factory (receives `onlyOwner` privileges).
    constructor(IVerifiableFactory verifiableFactory, address owner_) Ownable(owner_) {
        if (address(verifiableFactory) == address(0))
            revert VerifiableFactoryCannotBeZero();
        VERIFIABLE_FACTORY = verifiableFactory;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Sets whether an implementation may be used for HCA designation.
    /// @param implementation The implementation address to update.
    /// @param approved Whether the implementation is approved.
    function setImplementationApproval(address implementation, bool approved) external onlyOwner {
        if (implementation == address(0))
            revert HCAImplementationCannotBeZero();
        _approvedImplementations[implementation] = approved;
        emit HCAImplementationApprovalChanged(implementation, approved);
    }

    /// @notice Sets the deferred implementation users may explicitly select.
    /// @param implementation The deferred implementation address.
    function setDeferredImplementation(address implementation) external onlyOwner {
        if (implementation == address(0))
            revert DeferredImplementationCannotBeZero();
        deferredImplementation = implementation;
        emit DeferredImplementationSet(implementation);
    }

    /// @notice Explicitly pins the caller's HCA implementation.
    /// @dev `implementation` must be approved unless it is the configured deferred implementation.
    /// @param implementation The implementation the caller selects.
    function setAccountImplementation(address implementation) external {
        _requireSelectableImplementation(implementation);
        _accountImplementations[msg.sender] = implementation;
        emit AccountImplementationSet(msg.sender, implementation);
    }

    /// @notice Designates an existing verifiable proxy SCA as the caller's HCA.
    /// @dev The account must already be deployed through the verifiable factory and use an
    ///      approved implementation.
    /// @param hca The existing SCA to designate as the caller's HCA.
    /// @param implementation The expected approved implementation for the HCA.
    function setAccount(address hca, address implementation) external {
        _designateAccount(msg.sender, hca, implementation);
        emit AccountDesignated(msg.sender, hca, implementation);
    }

    /// @inheritdoc IHCAFactory
    function getAccountOwner(address hca) external view returns (address hcaOwner) {
        hcaOwner = _hcaOwners[hca];
        if (hcaOwner == address(0) && _accountImplementations[hca] == address(0)) {
            revert HCAImplementationNotSet(hca);
        }
    }

    /// @inheritdoc IHCAFactory
    function isApprovedImplementation(address implementation) external view returns (bool approved) {
        approved = _approvedImplementations[implementation];
    }

    /// @inheritdoc IHCAFactory
    function accountImplementationOf(address account) external view returns (address implementation) {
        implementation = _accountImplementations[account];
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Records the account owner after validating account code, implementation approval,
    ///      and verifiable deployment.
    /// @param hcaOwner The owner to record for the account.
    /// @param hca The account to designate.
    function _designateAccount(address hcaOwner, address hca, address implementation) internal {
        _requireRecordableAccount(hca);
        _requireSelectableImplementation(implementation);
        if (!VERIFIABLE_FACTORY.verifyContract(hca, implementation)) {
            revert HCAAccountNotVerifiable(hca, implementation);
        }
        _hcaOwners[hca] = hcaOwner;
        _accountImplementations[hca] = implementation;
    }

    /// @dev Reverts unless the account can be recorded as an HCA.
    /// @param hca The account to check.
    function _requireRecordableAccount(address hca) internal view {
        if (hca == address(0))
            revert HCAAccountCannotBeZero();
        if (hca.code.length == 0)
            revert HCAAccountHasNoCode(hca);
        address currentOwner = _hcaOwners[hca];
        if (currentOwner != address(0)) {
            revert HCAAccountAlreadyDesignated(hca, currentOwner);
        }
    }

    /// @dev Reverts unless the implementation is approved for HCA designation.
    /// @param implementation The implementation address to check.
    function _requireApprovedImplementation(address implementation) internal view {
        if (!_approvedImplementations[implementation]) {
            revert HCAImplementationNotApproved(implementation);
        }
    }

    /// @dev Reverts unless the implementation may be explicitly selected by an account.
    /// @param implementation The implementation address to check.
    function _requireSelectableImplementation(address implementation) internal view {
        if (implementation == address(0))
            revert HCAImplementationCannotBeZero();
        if (implementation == deferredImplementation) {
            return;
        }
        _requireApprovedImplementation(implementation);
    }
}
