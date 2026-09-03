// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {ECDSA} from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";
import {PackedUserOperation} from "account-abstraction/interfaces/PackedUserOperation.sol";

/// @dev Minimal ERC-4337 v0.7 account, owned by a single ECDSA key.
///      Deployed directly (no factory) so a UserOperation can be routed either
///      through a bundler or straight into `EntryPoint.handleOps()`.
contract MockEntryPointAccount {
    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    address public immutable ENTRY_POINT;
    address public immutable OWNER;

    uint256 public bumps;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    error NotEntryPoint(address caller);
    error DepositFailed();
    error ExecutionFailed(bytes reason);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(address entryPoint, address owner) {
        ENTRY_POINT = entryPoint;
        OWNER = owner;
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    receive() external payable {}

    function validateUserOp(
        PackedUserOperation calldata userOp,
        bytes32 userOpHash,
        uint256 missingAccountFunds
    )
        external
        returns (uint256 validationData)
    {
        if (msg.sender != ENTRY_POINT) revert NotEntryPoint(msg.sender);
        address signer =
            ECDSA.recover(MessageHashUtils.toEthSignedMessageHash(userOpHash), userOp.signature);
        validationData = signer == OWNER ? 0 : 1; // 1 == SIG_VALIDATION_FAILED
        if (missingAccountFunds != 0) {
            (bool sent,) = payable(msg.sender).call{value: missingAccountFunds}("");
            if (!sent) revert DepositFailed();
        }
    }

    function execute(address target, uint256 value, bytes calldata data) external {
        if (msg.sender != ENTRY_POINT) revert NotEntryPoint(msg.sender);
        (bool ok, bytes memory reason) = target.call{value: value}(data);
        if (!ok) revert ExecutionFailed(reason);
    }

    function bump() external {
        ++bumps;
    }
}
