// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {INexus} from "nexus/interfaces/INexus.sol";
import {IExecutor} from "nexus/interfaces/modules/IExecutor.sol";
import {ExecLib} from "nexus/lib/ExecLib.sol";
import {ModeLib} from "nexus/lib/ModeLib.sol";
import {EncodedModuleTypes} from "nexus/lib/ModuleTypeLib.sol";
import {Execution} from "nexus/types/DataTypes.sol";

import {
    OwnerBoundRegistrationSessionValidator
} from "~src/hca/OwnerBoundRegistrationSessionValidator.sol";

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

    /// @notice Rhinestone operation mode for ERC-1271 execution.
    bytes32 internal constant ERC7579_ERC1271_MODE = bytes32(uint256(0x0201) << 240);

    /// @notice Rhinestone operation mode for pure emissary execution.
    bytes32 internal constant ERC7579_EMISSARY_EXECUTION_MODE = bytes32(uint256(0x0204) << 240);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice The account did not accept the provided signature.
    /// @dev Error selector: `0x8baa579f`
    error InvalidSignature();

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
        bytes32 digest = keccak256(operationData);
        if (account.isValidSignature(digest, signature) != ERC1271_MAGICVALUE) {
            revert InvalidSignature();
        }

        return
            account.executeFromExecutor(ModeLib.encodeSimpleBatch(), ExecLib.encodeBatch(executions));
    }

    /// @notice Executes a batch after fixed-session verification.
    function executeWithSession(
        INexus account,
        OwnerBoundRegistrationSessionValidator validator,
        Execution[] calldata executions,
        bytes calldata signature
    )
        external
        returns (bytes[] memory returnData)
    {
        bytes memory operationData = encodeSessionOperation(executions);
        bytes32 digest = keccak256(operationData);
        OwnerBoundRegistrationSessionValidator.Operation memory operation =
            OwnerBoundRegistrationSessionValidator.Operation({data: operationData});
        if (
            validator.verifyExecution(address(account), digest, signature, operation) !=
            validator.verifyExecution.selector
        ) {
            revert InvalidSignature();
        }

        return
            account.executeFromExecutor(ModeLib.encodeSimpleBatch(), ExecLib.encodeBatch(executions));
    }

    /// @notice Encodes an ERC-7579 ERC-1271 batch operation payload.
    /// @param executions The executions to encode.
    /// @return The encoded operation payload consumed by the validator.
    function encodeOperation(Execution[] calldata executions) public pure returns (bytes memory) {
        return abi.encodePacked(ERC7579_ERC1271_MODE, abi.encode(executions));
    }

    /// @notice Encodes an ERC-7579 pure-emissary execution operation.
    /// @param executions The executions to encode.
    /// @return The encoded operation payload consumed by the validator.
    function encodeSessionOperation(Execution[] calldata executions)
        public
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(ERC7579_EMISSARY_EXECUTION_MODE, abi.encode(executions));
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
}
