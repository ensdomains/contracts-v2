// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {Nexus} from "nexus/Nexus.sol";

import {IHCA} from "./IHCA.sol";
import {IHCAFactory} from "./IHCAFactory.sol";
import {IK1Validator} from "./IK1Validator.sol";

contract HCA is Nexus, IHCA {
    IHCAFactory private immutable _HCA_FACTORY;

    error HCAFactoryCannotBeZero();

    error CallerNotHCAFactory();

    error UninstallModuleNotAllowed();

    modifier onlyHCAFactory() {
        if (msg.sender != address(_HCA_FACTORY)) revert CallerNotHCAFactory();
        _;
    }

    constructor(
        IHCAFactory hcaFactory_,
        address entryPoint_,
        address defaultValidator_,
        bytes memory initDataTemplate_
    ) Nexus(entryPoint_, defaultValidator_, initDataTemplate_) {
        if (address(hcaFactory_) == address(0)) revert HCAFactoryCannotBeZero();
        _HCA_FACTORY = hcaFactory_;
    }

    function installModule(
        uint256 moduleTypeId,
        address module,
        bytes calldata initData
    ) external payable virtual override {
        if (isInitialized()) revert AccountAlreadyInitialized();
        _installModule(moduleTypeId, module, initData);
        emit ModuleInstalled(moduleTypeId, module);
    }

    function getOwner() external view returns (address) {
        // we will only ever use the default validator
        return IK1Validator(_DEFAULT_VALIDATOR).getOwner(address(this));
    }

    function _authorizeUpgrade(
        address newImplementation
    ) internal virtual override onlyHCAFactory {
        super._authorizeUpgrade(newImplementation);
    }

    function _uninstallValidator(
        address,
        /* validator */ bytes calldata /* data */
    ) internal virtual override {
        revert UninstallModuleNotAllowed();
    }

    function _uninstallExecutor(
        address,
        /* executor */ bytes calldata /* data */
    ) internal virtual override {
        revert UninstallModuleNotAllowed();
    }

    function _uninstallFallbackHandler(
        address,
        /* fallbackHandler */ bytes calldata /* data */
    ) internal virtual override {
        revert UninstallModuleNotAllowed();
    }

    function _uninstallHook(
        address,
        /* hook */ uint256,
        /* hookType */ bytes calldata /* data */
    ) internal virtual override {
        revert UninstallModuleNotAllowed();
    }
}
