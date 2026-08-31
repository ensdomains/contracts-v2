// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Execution} from "nexus/types/DataTypes.sol";

/// @title HCA Operation Hash Library
/// @notice Reconstructs the operation hashes used by Rhinestone intents.
/// @dev Decodes the operation tuple shared by the HCA validation policies.
library HCAOperationHashLib {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Intent operation-call type hash.
    bytes32 internal constant EXECUTION_TYPEHASH =
        keccak256("Ops(address to,uint256 value,bytes data)");

    /// @dev Intent operation type hash.
    bytes32 internal constant OPERATION_TYPEHASH =
        keccak256("Op(bytes32 vt,Ops[] ops)Ops(address to,uint256 value,bytes data)");

    /// @notice Rhinestone operation mode for ERC-1271 ERC-7579 execution.
    /// @dev Encoded in the most significant bytes of the operation mode word.
    bytes32 internal constant ERC7579_ERC1271_MODE = bytes32(uint256(0x0201) << 240);

    /// @notice Rhinestone operation mode for emissary ERC-7579 execution.
    /// @dev Encoded in the most significant bytes of the operation mode word.
    bytes32 internal constant ERC7579_EMISSARY_EXECUTION_MODE = bytes32(uint256(0x0204) << 240);

    /// @notice Rhinestone operation mode for ERC-1271 with emissary-execution fallback.
    /// @dev Encoded in the most significant bytes of the operation mode word.
    bytes32 internal constant ERC7579_ERC1271_EMISSARY_EXECUTION_MODE =
        bytes32(uint256(0x0206) << 240);

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Checks whether an operation mode can execute an HCA policy-controlled batch.
    /// @dev Accepts the ERC-1271 and emissary execution variants supported by the HCA.
    /// @param mode The Rhinestone operation mode.
    /// @return supported Whether the mode is supported by an HCA validator.
    function isSupportedMode(bytes32 mode) internal pure returns (bool supported) {
        return
            mode == ERC7579_ERC1271_MODE ||
            mode == ERC7579_EMISSARY_EXECUTION_MODE ||
            mode == ERC7579_ERC1271_EMISSARY_EXECUTION_MODE;
    }

    /// @notice Checks whether an operation mode binds execution through ERC-1271.
    /// @dev Excludes the emissary-only execution variant.
    /// @param mode The Rhinestone operation mode.
    /// @return supported Whether the mode uses ERC-1271 authorization.
    function isERC1271Mode(bytes32 mode) internal pure returns (bool supported) {
        return mode == ERC7579_ERC1271_MODE || mode == ERC7579_ERC1271_EMISSARY_EXECUTION_MODE;
    }

    /// @notice Hashes an encoded ERC-7579 operation as the IntentExecutor does.
    /// @dev The caller must validate the operation mode and ensure that `operationData` contains
    ///      its leading mode word before calling this function.
    /// @param operationData The operation mode followed by an ABI-encoded execution array.
    /// @return operationHash The EIP-712 operation struct hash.
    function hash(bytes calldata operationData) internal pure returns (bytes32 operationHash) {
        bytes32 mode = bytes32(operationData[:32]);
        Execution[] memory executions = abi.decode(operationData[32:], (Execution[]));
        bytes32[] memory executionHashes = new bytes32[](executions.length);
        for (uint256 i; i < executions.length; ++i) {
            Execution memory execution = executions[i];
            executionHashes[i] = keccak256(
                abi.encode(
                    EXECUTION_TYPEHASH,
                    execution.target,
                    execution.value,
                    keccak256(execution.callData)
                )
            );
        }
        return
            keccak256(
                abi.encode(OPERATION_TYPEHASH, mode, keccak256(abi.encodePacked(executionHashes)))
            );
    }
}
