// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IProxyAuthorization} from "@ensdomains/verifiable-factory/IProxyAuthorization.sol";
import {IModule} from "nexus/interfaces/modules/IModule.sol";
import {Nexus} from "nexus/Nexus.sol";
import {Execution} from "nexus/types/DataTypes.sol";

import {ApprovedUpgradeGate} from "../registry/ApprovedUpgradeGate.sol";

/// @title Standalone Single Owner HCA
/// @notice Nexus account whose owner is set once during account initialization.
/// @dev Module changes are disabled after initialization and the configured default validator
///      remains the only validator path for the account. Upgrades are owner-triggered and
///      restricted to implementations approved by the upgrade gate.
contract StandaloneSingleOwnerHCA is Nexus, IProxyAuthorization {
    ////////////////////////////////////////////////////////////////////////
    // Constants & Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice Selector for ERC-721 token receipt.
    /// @dev Returned by `onERC721Received`.
    bytes4 internal constant ERC721_RECEIVED_SELECTOR = 0x150b7a02;

    /// @notice Selector for single ERC-1155 token receipt.
    /// @dev Returned by `onERC1155Received`.
    bytes4 internal constant ERC1155_RECEIVED_SELECTOR = 0xf23a6e61;

    /// @notice Selector for batched ERC-1155 token receipt.
    /// @dev Returned by `onERC1155BatchReceived`.
    bytes4 internal constant ERC1155_BATCH_RECEIVED_SELECTOR = 0xbc197c81;

    /// @notice The allowlist gating upgrade target implementations.
    ApprovedUpgradeGate public immutable UPGRADE_GATE;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice The initialized account owner.
    /// @dev Set once during `initializeAccount`.
    address private _owner;

    /// @notice The nonce bound to every enabled fixed session.
    /// @dev Packed into the `_owner` slot and incremented by `revokeSessions`.
    uint96 private _sessionNonce;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice All enabled sessions were revoked.
    /// @param sessionNonce The new session nonce.
    event SessionsRevoked(uint96 indexed sessionNonce);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0x9b15e16f`
    error OwnerCannotBeZero();

    /// @dev Error selector: `0xa413196e`
    error StandaloneHCAAlreadyInitialized();

    /// @dev Error selector: `0xca962ccf`
    error NoModuleChangeAllowed();

    /// @dev Error selector: `0x5cd83192`
    error CallerNotOwner();

    /// @dev Error selector: `0xf74d7dd0`
    /// @param implementation The disallowed implementation address.
    error UpgradeTargetNotApproved(address implementation);

    /// @dev Error selector: `0x6e29a697`
    error NoNFTAllowed();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param entryPoint_ ERC-4337 EntryPoint used by Nexus.
    /// @param defaultValidator_ Validator module used as the account's default validator.
    /// @param intentExecutor_ Executor module used by the intent execution flow.
    /// @param validatorInitData_ Initialization data passed to the default validator.
    /// @param upgradeGate_ The allowlist gating upgrade target implementations.
    constructor(
        address entryPoint_,
        address defaultValidator_,
        address intentExecutor_,
        bytes memory validatorInitData_,
        ApprovedUpgradeGate upgradeGate_
    )
        Nexus(entryPoint_, defaultValidator_, intentExecutor_, validatorInitData_, "")
    {
        UPGRADE_GATE = upgradeGate_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the account owner.
    /// @param initData ABI-encoded owner address.
    function initializeAccount(bytes calldata initData) external payable override {
        if (_owner != address(0)) {
            revert StandaloneHCAAlreadyInitialized();
        }

        address initialOwner = abi.decode(initData, (address));
        if (initialOwner == address(0)) {
            revert OwnerCannotBeZero();
        }

        _owner = initialOwner;
        IModule(_DEFAULT_EXECUTOR).onInstall("");
    }

    /// @notice Disables module installation.
    /// @param moduleTypeId Unused module type id.
    /// @param module Unused module address.
    /// @param initData Unused module initialization data.
    function installModule(uint256 moduleTypeId, address module, bytes calldata initData)
        external
        payable
        override
    {
        moduleTypeId;
        module;
        initData;

        revert NoModuleChangeAllowed();
    }

    /// @notice Disables module uninstallation.
    /// @param moduleTypeId Unused module type id.
    /// @param module Unused module address.
    /// @param deInitData Unused module de-initialization data.
    function uninstallModule(uint256 moduleTypeId, address module, bytes calldata deInitData)
        external
        payable
        override
    {
        moduleTypeId;
        module;
        deInitData;

        revert NoModuleChangeAllowed();
    }

    /// @notice Invalidates every enabled session for this account.
    /// @dev Increments the nonce checked by the fixed validator. Only callable by the owner
    ///      directly; account execution paths cannot reach it because self-calls carry the
    ///      account as `msg.sender`.
    function revokeSessions() external {
        if (msg.sender != _owner) {
            revert CallerNotOwner();
        }
        uint96 sessionNonce;
        unchecked {
            sessionNonce = ++_sessionNonce;
        }
        emit SessionsRevoked(sessionNonce);
    }

    /// @notice Returns the account owner.
    function owner() external view returns (address) {
        return _owner;
    }

    /// @notice Returns the account owner and current session nonce.
    /// @return owner_ The account owner.
    /// @return sessionNonce_ The current session nonce.
    function ownerAndSessionNonce() external view returns (address owner_, uint96 sessionNonce_) {
        return (_owner, _sessionNonce);
    }

    /// @notice Executes an atomic batch submitted directly by the account owner.
    /// @dev The wallet transaction authenticates the owner, so this path does not require an
    ///      intent signature or the default executor. The session policy does not apply, and
    ///      each inner call is made by the HCA.
    /// @param executions The calls to execute in order.
    function executeByOwner(Execution[] calldata executions) external payable onlyProxy {
        if (msg.sender != _owner) {
            revert CallerNotOwner();
        }
        _executeBatchNoReturndata(executions);
    }

    /// @notice Declares this implementation as an eligible verifiable proxy upgrade target.
    /// @dev Compatibility hook only — upgrade authorization is enforced by the current
    ///      implementation's `_authorizeUpgrade` during the UUPS upgrade call.
    /// @param {previousImplementation} Ignored.
    /// @return allowed Always `true` for implementations in this account family.
    function canUpgradeFrom(
        address /* previousImplementation */
    )
        external
        pure
        override
        returns (bool allowed)
    {
        return true;
    }

    /// @notice Returns the account implementation identifier.
    function accountId() external pure override returns (string memory) {
        return "ens-standalone-hca.1.1.0";
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Rejects NFT receiver callbacks before forwarding other fallback calls to Nexus.
    function _fallback(bytes calldata callData) internal override {
        if (callData.length >= 4) {
            bytes4 selector = bytes4(callData[0:4]);
            if (selector == ERC721_RECEIVED_SELECTOR) {
                revert NoNFTAllowed();
            }
            if (selector == ERC1155_RECEIVED_SELECTOR) {
                revert NoNFTAllowed();
            }
            if (selector == ERC1155_BATCH_RECEIVED_SELECTOR) {
                revert NoNFTAllowed();
            }
        }

        super._fallback(callData);
    }

    /// @dev Requires the owner as caller and gate approval for the target implementation.
    /// @param newImplementation The implementation to upgrade to.
    function _authorizeUpgrade(address newImplementation) internal view override {
        if (msg.sender != _owner) {
            revert CallerNotOwner();
        }
        if (!UPGRADE_GATE.approvedImplementations(newImplementation)) {
            revert UpgradeTargetNotApproved(newImplementation);
        }
    }
}
