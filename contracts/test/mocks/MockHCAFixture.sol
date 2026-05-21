// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IHCAInitDataParser} from "~src/hca/interfaces/IHCAInitDataParser.sol";

/// @title Mock HCA Init Data Parser
/// @notice Decodes a single owner address from HCA initialization data.
contract MockHCAInitDataParser is IHCAInitDataParser {
    /// @inheritdoc IHCAInitDataParser
    function getOwnerFromInitData(bytes calldata initData)
        external
        pure
        returns (address hcaOwner)
    {
        hcaOwner = abi.decode(initData, (address));
    }
}

/// @title Mock HCA Executor Implementation
/// @notice Minimal owner-controlled account implementation for HCA end-to-end tests.
contract MockHCAExecutorImplementation {
    /// @notice The account authorized to execute calls through the HCA.
    address public owner;

    /// @notice Thrown when the account has already been initialized.
    error HCAExecutorAlreadyInitialized();

    /// @notice Thrown when a caller is not authorized to execute through the account.
    /// @param caller The unauthorized caller.
    /// @param owner_ The authorized owner.
    error HCAExecutorUnauthorized(address caller, address owner_);

    /// @notice Thrown when an executed call reverts.
    /// @param returndata The revert data returned by the target.
    error HCAExecutorCallFailed(bytes returndata);

    /// @notice Initializes the executor owner.
    /// @param owner_ The account authorized to execute calls.
    function initialize(address owner_) external {
        if (owner != address(0))
            revert HCAExecutorAlreadyInitialized();
        owner = owner_;
    }

    /// @notice Executes a call as the HCA.
    /// @param target The target contract to call.
    /// @param data The calldata to forward.
    /// @return result The data returned by the target call.
    function execute(address target, bytes calldata data)
        external
        returns (bytes memory result)
    {
        address currentOwner = owner;
        if (msg.sender != currentOwner)
            revert HCAExecutorUnauthorized(msg.sender, currentOwner);

        (bool success, bytes memory returndata) = target.call(data);
        if (!success)
            revert HCAExecutorCallFailed(returndata);
        result = returndata;
    }
}
