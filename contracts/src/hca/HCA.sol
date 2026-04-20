// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Nexus} from "nexus/Nexus.sol";

import {IHCA} from "./IHCA.sol";
import {IHCAFactory} from "./IHCAFactory.sol";
import {IK1Validator} from "./IK1Validator.sol";

/// @notice Nexus account implementation controlled by an HCA factory.
contract HCA is Nexus, IHCA {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @dev Factory allowed to upgrade accounts and create account instances.
    IHCAFactory private immutable _HCA_FACTORY;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0x841d6202`
    error HCAFactoryCannotBeZero();

    /// @dev Error selector: `0x9a8c7026`
    error CallerNotHCAFactory();

    /// @dev Error selector: `0xef2988e8`
    error UninstallModuleNotAllowed();

    ////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////

    modifier onlyHCAFactory() {
        if (msg.sender != address(_HCA_FACTORY))
            revert CallerNotHCAFactory();
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Creates an HCA implementation bound to its factory and default module setup.
    /// @param hcaFactory_ The factory allowed to manage factory-only operations.
    /// @param entryPoint_ The ERC-4337 entry point used by the Nexus base account.
    /// @param defaultValidator_ The validator installed as the default module.
    /// @param initDataTemplate_ The initialization data template passed to Nexus.
    constructor(
        IHCAFactory hcaFactory_,
        address entryPoint_,
        address defaultValidator_,
        bytes memory initDataTemplate_
    )
        Nexus(entryPoint_, defaultValidator_, initDataTemplate_)
    {
        if (address(hcaFactory_) == address(0))
            revert HCAFactoryCannotBeZero();
        _HCA_FACTORY = hcaFactory_;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Installs the initial module before the account has been initialized.
    /// @param moduleTypeId The ERC-7579 module type to install.
    /// @param module The module contract to install.
    /// @param initData The module initialization calldata.
    function installModule(uint256 moduleTypeId, address module, bytes calldata initData)
        external
        payable
        virtual
        override
    {
        if (isInitialized())
            revert AccountAlreadyInitialized();
        _installModule(moduleTypeId, module, initData);
        emit ModuleInstalled(moduleTypeId, module);
    }

    /// @notice Returns the owner reported by the default validator for this account.
    function getOwner() external view returns (address) {
        // we will only ever use the default validator
        return IK1Validator(_DEFAULT_VALIDATOR).getOwner(address(this));
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Restricts implementation upgrades to the account factory.
    function _authorizeUpgrade(address newImplementation) internal virtual override onlyHCAFactory {
        super._authorizeUpgrade(newImplementation);
    }

    /// @dev Prevents validator uninstallation for HCA accounts.
    function _uninstallValidator(
        address /* validator */,
        bytes calldata /* data */
    )
        internal
        virtual
        override
    {
        revert UninstallModuleNotAllowed();
    }

    /// @dev Prevents executor uninstallation for HCA accounts.
    function _uninstallExecutor(
        address /* executor */,
        bytes calldata /* data */
    )
        internal
        virtual
        override
    {
        revert UninstallModuleNotAllowed();
    }

    /// @dev Prevents fallback handler uninstallation for HCA accounts.
    function _uninstallFallbackHandler(
        address /* fallbackHandler */,
        bytes calldata /* data */
    )
        internal
        virtual
        override
    {
        revert UninstallModuleNotAllowed();
    }

    /// @dev Prevents hook uninstallation for HCA accounts.
    function _uninstallHook(
        address /* hook */,
        uint256 /* hookType */,
        bytes calldata /* data */
    )
        internal
        virtual
        override
    {
        revert UninstallModuleNotAllowed();
    }
}
