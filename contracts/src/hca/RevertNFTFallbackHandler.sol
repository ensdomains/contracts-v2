// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IFallback} from "nexus/interfaces/modules/IFallback.sol";
import {MODULE_TYPE_FALLBACK} from "nexus/types/Constants.sol";

/// @notice Fallback module that rejects NFT receiver callbacks for HCA accounts.
contract RevertNFTFallbackHandler is IFallback {
    /// @notice Rejects any unsupported fallback call.
    fallback() external {
        revert("");
    }

    /// @notice Handles module installation without additional setup.
    /// @param data Ignored module installation data.
    function onInstall(bytes calldata data) external {
        data;
    }

    /// @notice Handles module uninstallation without additional cleanup.
    /// @param data Ignored module uninstallation data.
    function onUninstall(bytes calldata data) external {
        data;
    }

    /// @notice Returns whether this module supports the requested module type.
    /// @param moduleTypeId The module type to check.
    /// @return True when the module type is fallback.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_FALLBACK;
    }

    /// @notice Returns whether the module is initialized for an account.
    /// @param smartAccount Ignored smart account address.
    /// @return Always true because this module has no account-specific state.
    function isInitialized(address smartAccount) external pure returns (bool) {
        smartAccount;
        return true;
    }
}
