// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";
import {IExecutor} from "nexus/interfaces/modules/IExecutor.sol";
import {IValidator} from "nexus/interfaces/modules/IValidator.sol";
import {EncodedModuleTypes} from "nexus/lib/ModuleTypeLib.sol";

import {
    OwnerBoundRegistrationSessionValidator
} from "~src/hca/OwnerBoundRegistrationSessionValidator.sol";

/// @title Mock Standalone HCA
/// @notice Test-only HCA stand-in that exposes an owner and forwards validation.
contract MockStandaloneHCA {
    /// @notice The owner reported to the validator.
    address public owner;

    /// @param owner_ The owner reported to the validator.
    constructor(address owner_) {
        owner = owner_;
    }

    /// @notice Forwards an ERC-1271 validation to the validator as this account.
    /// @param validator The validator under test.
    /// @param operationHash The digest supplied by the intent executor.
    /// @param signature The encoded signature envelope.
    /// @return The ERC-1271 return value.
    function validate(
        OwnerBoundRegistrationSessionValidator validator,
        bytes32 operationHash,
        bytes calldata signature
    )
        external
        view
        returns (bytes4)
    {
        return validator.isValidSignatureWithSender(address(this), operationHash, signature);
    }
}


/// @title Mock Validator Module
/// @notice Test-only ERC-7579 validator that rejects user operations.
contract MockValidatorModule is IValidator {
    /// @notice Always fails ERC-4337 validation.
    function validateUserOp(PackedUserOperation calldata, bytes32) external pure returns (uint256) {
        return 1;
    }

    /// @notice Always fails ERC-1271 validation.
    function isValidSignatureWithSender(address, bytes32, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return bytes4(0);
    }

    /// @notice No-op install hook.
    function onInstall(bytes calldata) external pure {}

    /// @notice No-op uninstall hook.
    function onUninstall(bytes calldata) external pure {}

    /// @notice Reports the validator module type.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 1;
    }

    /// @notice Always reports initialized.
    function isInitialized(address) external pure returns (bool) {
        return true;
    }
}


/// @title Mock Executor Module
/// @notice Test-only ERC-7579 executor with no behavior.
contract MockExecutorModule is IExecutor {
    /// @notice No-op install hook.
    function onInstall(bytes calldata) external pure {}

    /// @notice No-op uninstall hook.
    function onUninstall(bytes calldata) external pure {}

    /// @notice Reports the executor module type.
    function isModuleType(uint256 moduleTypeId) external pure returns (bool) {
        return moduleTypeId == 2;
    }

    /// @notice Unused module-type encoding.
    function getModuleTypes() external pure returns (EncodedModuleTypes) {}

    /// @notice Always reports initialized.
    function isInitialized(address) external pure returns (bool) {
        return true;
    }
}


/// @title Mock Verifiable Factory
/// @notice Test-only factory that records deployProxy arguments.
contract MockVerifiableFactory {
    /// @notice The last implementation passed to deployProxy.
    address public implementation;

    /// @notice The last salt passed to deployProxy.
    uint256 public salt;

    /// @notice The last init data passed to deployProxy.
    bytes public initData;

    /// @notice The proxy address returned by deployProxy.
    address public proxy = address(0xBEEF);

    /// @notice Records the deployment arguments and returns the fixed proxy.
    /// @param implementation_ The implementation address.
    /// @param salt_ The deployment salt.
    /// @param data_ Initialization calldata for the proxy.
    /// @return The fixed proxy address.
    function deployProxy(address implementation_, uint256 salt_, bytes calldata data_)
        external
        returns (address)
    {
        implementation = implementation_;
        salt = salt_;
        initData = data_;
        return proxy;
    }
}


/// @title Mock Registration Committer
/// @notice Test-only registrar that records the last commitment.
contract MockRegistrationCommitter {
    /// @notice The last commitment written.
    bytes32 public commitment;

    /// @notice Records a registration commitment.
    /// @param commitment_ The commitment hash.
    function commit(bytes32 commitment_) external {
        commitment = commitment_;
    }
}
