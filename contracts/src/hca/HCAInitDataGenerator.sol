// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {IInitDataGenerator} from "./IInitDataGenerator.sol";
import {NexusBootstrap, BootstrapConfig, BootstrapPreValidationHookConfig} from "nexus/utils/NexusBootstrap.sol";
import {RevertNFTFallbackHandler} from "./RevertNFTFallbackHandler.sol";
import {CALLTYPE_SINGLE} from "nexus/lib/ModeLib.sol";

/**
 * @title HCAInitDataGenerator
 * @notice A specific implementation of IInitDataGenerator for HCA accounts
 * @dev Self-contained generator with built-in bootstrap configuration
 */
contract HCAInitDataGenerator is IInitDataGenerator {
    address public immutable bootstrap;

    address public immutable revertNFTFallbackHandler;

    constructor(address bootstrap_) {
        bootstrap = bootstrap_;
        revertNFTFallbackHandler = address(new RevertNFTFallbackHandler());
    }

    /**
     * @notice Generates account-specific init data with the specified owner
     * @param owner The actual owner address to use
     * @return The generated init data with the correct owner
     */
    function generateInitData(
        address owner
    ) external view override returns (bytes memory) {
        // Create fallback configurations for ERC721/ERC1155 token rejections
        BootstrapConfig[] memory fallbacks = new BootstrapConfig[](3);
        fallbacks[0] = BootstrapConfig(
            revertNFTFallbackHandler,
            abi.encodePacked(bytes4(0x150b7a02), CALLTYPE_SINGLE)
        );
        fallbacks[1] = BootstrapConfig(
            revertNFTFallbackHandler,
            abi.encodePacked(bytes4(0xf23a6e61), CALLTYPE_SINGLE)
        );
        fallbacks[2] = BootstrapConfig(
            revertNFTFallbackHandler,
            abi.encodePacked(bytes4(0xbc197c81), CALLTYPE_SINGLE)
        );

        // Create validator data with the actual owner
        bytes memory validatorData = abi.encodePacked(owner);

        // Create the bootstrap call with the correct owner
        bytes memory bootstrapCall = abi.encodeCall(
            NexusBootstrap
                .initNexusWithDefaultValidatorAndOtherModulesNoRegistry,
            (
                validatorData,
                new BootstrapConfig[](0),
                new BootstrapConfig[](0),
                BootstrapConfig(address(0), hex""),
                fallbacks,
                new BootstrapPreValidationHookConfig[](0)
            )
        );

        // Return the complete init data
        return abi.encode(bootstrap, bootstrapCall);
    }
}
