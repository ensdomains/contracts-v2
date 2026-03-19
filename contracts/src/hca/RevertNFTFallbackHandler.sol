// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IFallback} from "nexus/interfaces/modules/IFallback.sol";
import {MODULE_TYPE_FALLBACK} from "nexus/types/Constants.sol";

contract RevertNFTFallbackHandler is IFallback {
    fallback() external {
        revert("");
    }

    function onInstall(bytes calldata /* data */) external {}

    function onUninstall(bytes calldata /* data */) external {}

    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_FALLBACK;
    }

    function isInitialized(
        address /* smartAccount */
    ) external pure returns (bool) {
        return true;
    }
}
