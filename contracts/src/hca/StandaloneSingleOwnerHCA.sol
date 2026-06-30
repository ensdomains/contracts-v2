// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IModule} from "nexus/interfaces/modules/IModule.sol";
import {Nexus} from "nexus/Nexus.sol";

/// @title Standalone Single Owner HCA
/// @notice Nexus account whose owner is set once during account initialization.
/// @dev Module changes and upgrades are disabled after initialization. The configured default
///      validator remains the only validator path for the account.
contract StandaloneSingleOwnerHCA is Nexus {
    ////////////////////////////////////////////////////////////////////////
    // Constants
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

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice The initialized account owner.
    /// @dev Set once during `initializeAccount`.
    address private _owner;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0x9b15e16f`
    error OwnerCannotBeZero();

    /// @dev Error selector: `0xa413196e`
    error StandaloneHCAAlreadyInitialized();

    /// @dev Error selector: `0xca962ccf`
    error NoModuleChangeAllowed();

    /// @dev Error selector: `0x9bc73842`
    error HCAUpgradeDisabled();

    /// @dev Error selector: `0x6e29a697`
    error NoNFTAllowed();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param entryPoint_ ERC-4337 EntryPoint used by Nexus.
    /// @param defaultValidator_ Validator module used as the account's default validator.
    /// @param intentExecutor_ Executor module used by the intent execution flow.
    /// @param validatorInitData_ Initialization data passed to the default validator.
    constructor(
        address entryPoint_,
        address defaultValidator_,
        address intentExecutor_,
        bytes memory validatorInitData_
    )
        Nexus(entryPoint_, defaultValidator_, intentExecutor_, validatorInitData_, "")
    {}

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

    /// @notice Returns the account owner.
    function owner() external view returns (address) {
        return _owner;
    }

    /// @notice Returns the account implementation identifier.
    function accountId() external pure override returns (string memory) {
        return "ens-standalone-hca.1.0.0";
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

    /// @dev Disables UUPS upgrades.
    function _authorizeUpgrade(address) internal pure override {
        revert HCAUpgradeDisabled();
    }
}
