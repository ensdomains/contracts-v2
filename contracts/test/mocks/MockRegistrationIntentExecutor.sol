// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {INexus} from "nexus/interfaces/INexus.sol";
import {IExecutor} from "nexus/interfaces/modules/IExecutor.sol";
import {ExecLib} from "nexus/lib/ExecLib.sol";
import {ModeLib} from "nexus/lib/ModeLib.sol";
import {EncodedModuleTypes} from "nexus/lib/ModuleTypeLib.sol";
import {Execution} from "nexus/types/DataTypes.sol";

/// @title Mock Registration Intent Executor
/// @notice Test-only executor that validates the HCA's ERC-1271 signature before executing.
contract MockRegistrationIntentExecutor is IExecutor {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice Standard ERC-1271 success return value.
    /// @dev Returned by ERC-1271 validators for valid signatures.
    bytes4 internal constant ERC1271_MAGICVALUE = 0x1626ba7e;

    /// @notice ERC-7579 executor module type id.
    /// @dev Module type ID for executor modules.
    uint256 internal constant MODULE_TYPE_EXECUTOR = 2;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The account did not accept the provided signature.
    /// @dev Error selector: `0x8baa579f`
    error InvalidSignature();

    /// @notice The signature envelope was not encoded for this operation.
    /// @dev Error selector: `0xa196e928`
    error OperationDataMismatch();

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Executes a batch after validating the account's registration signature.
    /// @param account The standalone HCA account.
    /// @param executions The ERC-7579 executions to run through the account.
    /// @param signature The ERC-1271 signature routed to the account's default validator.
    /// @return returnData Return data from the account execution.
    function execute(INexus account, Execution[] calldata executions, bytes calldata signature)
        external
        returns (bytes[] memory returnData)
    {
        bytes memory operationData = encodeOperation(executions);
        _checkSignedOperationData(signature, operationData);

        bytes32 digest = keccak256(operationData);
        if (account.isValidSignature(digest, signature) != ERC1271_MAGICVALUE) {
            revert InvalidSignature();
        }

        return
            account.executeFromExecutor(ModeLib.encodeSimpleBatch(), ExecLib.encodeBatch(executions));
    }

    /// @notice Encodes an ERC-7579 ERC-1271 batch operation payload.
    /// @param executions The executions to encode.
    /// @return The encoded operation payload consumed by the validator.
    function encodeOperation(Execution[] calldata executions) public pure returns (bytes memory) {
        return abi.encodePacked(bytes1(uint8(2)), bytes1(uint8(1)), abi.encode(executions));
    }

    /// @notice No-op install hook for ERC-7579 compatibility.
    /// @param data Unused install data.
    function onInstall(bytes calldata data) external pure {
        data;
    }

    /// @notice No-op uninstall hook for ERC-7579 compatibility.
    /// @param data Unused uninstall data.
    function onUninstall(bytes calldata data) external pure {
        data;
    }

    /// @notice Returns whether this module is an executor.
    /// @param moduleTypeId The ERC-7579 module type id.
    /// @return True when the module type is executor.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == MODULE_TYPE_EXECUTOR;
    }

    /// @notice Returns the encoded module types supported by this module.
    function getModuleTypes() external pure returns (EncodedModuleTypes) {}

    /// @notice Returns whether this stateless module is initialized for an account.
    /// @param account Unused account address.
    /// @return Always true because there is no per-account storage.
    function isInitialized(address account) external pure returns (bool) {
        account;

        return true;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Ensures the validator's embedded operation data matches the executor operation.
    function _checkSignedOperationData(bytes calldata signature, bytes memory operationData)
        internal
        pure
    {
        if (signature.length < 20 + 12 * 32) {
            revert OperationDataMismatch();
        }

        uint256 operationDataHead = 20 + 11 * 32;
        uint256 operationDataOffset;
        assembly ("memory-safe") {
            operationDataOffset := calldataload(add(signature.offset, operationDataHead))
        }

        uint256 lengthOffset = 20 + operationDataOffset;
        if (signature.length < lengthOffset + 32) {
            revert OperationDataMismatch();
        }

        uint256 signedOperationDataLength;
        assembly ("memory-safe") {
            signedOperationDataLength := calldataload(add(signature.offset, lengthOffset))
        }

        uint256 signedOperationDataOffset = lengthOffset + 32;
        if (signature.length < signedOperationDataOffset + signedOperationDataLength) {
            revert OperationDataMismatch();
        }

        bytes32 signedOperationDataHash;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            calldatacopy(
                ptr,
                add(signature.offset, signedOperationDataOffset),
                signedOperationDataLength
            )
            signedOperationDataHash := keccak256(ptr, signedOperationDataLength)
            mstore(0x40, add(ptr, and(add(signedOperationDataLength, 0x3f), not(0x1f))))
        }

        if (signedOperationDataHash != keccak256(operationData)) {
            revert OperationDataMismatch();
        }
    }
}
