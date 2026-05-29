// SPDX-License-Identifier: MIT

// Canonical Yul source for ProxyLib.INITIALIZED_HCA_PROXY_INIT_CODE_PREFIX.
object "HCAProxyInitCode" {
    code {
        // Point to the bytes appended immediately after the embedded runtime object.
        let implementationOffset := add(dataoffset("HCAProxyRuntime"), datasize("HCAProxyRuntime"))
        // Copy the appended implementation address so it is right-aligned in the first memory word.
        codecopy(0x0c, implementationOffset, 0x14)
        // Load the right-aligned implementation address from memory.
        let implementation := mload(0x00)

        // Reject implementations without deployed code, matching ERC1967Utils.
        if iszero(extcodesize(implementation)) {
            // Store the ERC1967InvalidImplementation(address) selector.
            mstore(0x00, shl(224, 0x4c9c8ce3))
            // Store the invalid implementation argument after the selector.
            mstore(0x04, implementation)
            // Revert with the selector and encoded address argument.
            revert(0x00, 0x24)
        }

        // Store the implementation in the ERC1967 implementation slot.
        sstore(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc, implementation)
        // Emit Upgraded(address) with the implementation as the indexed argument.
        log2(0x00, 0x00, 0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b, implementation)

        // Enable constructor-only initialization for the delegated initializer call.
        tstore(0x90b772c2cb8a51aa7a8a65fc23543c6d022d5b3f8e2b92eed79fba7eef829300, 0x01)

        // Point to the initializer calldata appended after the implementation address.
        let initializerOffset := add(implementationOffset, 0x14)
        // Treat all remaining init code bytes as initializer calldata.
        let initializerSize := sub(codesize(), initializerOffset)
        // Copy initializer calldata into memory for the delegatecall.
        codecopy(0x00, initializerOffset, initializerSize)

        // Delegate the initializer calldata into the implementation.
        let success := delegatecall(gas(), implementation, 0x00, initializerSize, 0x00, 0x00)
        // Copy return data so success and failure both preserve implementation output.
        returndatacopy(0x00, 0x00, returndatasize())
        // Bubble initializer reverts.
        if iszero(success) { revert(0x00, returndatasize()) }

        // Copy the runtime object into memory as the deployed proxy code.
        datacopy(0x00, dataoffset("HCAProxyRuntime"), datasize("HCAProxyRuntime"))
        // Return the runtime object as the deployed proxy code.
        return(0x00, datasize("HCAProxyRuntime"))
    }

    object "HCAProxyRuntime" {
        code {
            // Accept plain ETH transfers without delegating empty calldata.
            if iszero(calldatasize()) { stop() }

            // Copy calldata into memory for delegation.
            calldatacopy(0x00, 0x00, calldatasize())
            // Delegate the call to the implementation currently stored in the ERC1967 implementation slot.
            let success := delegatecall(
                // Forward all remaining gas.
                gas(),
                // Load the current implementation from ERC1967 storage.
                sload(0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc),
                // Use memory offset zero as the input buffer.
                0x00,
                // Use the full calldata length as the input size.
                calldatasize(),
                // Use memory offset zero as the output buffer placeholder.
                0x00,
                // Let returndatacopy handle the final output size.
                0x00
            )
            // Copy return data into memory for bubbling.
            returndatacopy(0x00, 0x00, returndatasize())
            // Bubble delegatecall reverts.
            if iszero(success) { revert(0x00, returndatasize()) }
            // Return delegatecall output to the original caller.
            return(0x00, returndatasize())
        }
    }
}
