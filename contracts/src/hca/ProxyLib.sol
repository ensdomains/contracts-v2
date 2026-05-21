// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {NexusProxy} from "nexus/utils/NexusProxy.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

/// @notice Minimal initializer interface for Nexus-compatible account implementations.
/// @dev Interface selector: `0x4b6a1419`
interface INexusAccountInitializer {
    /// @notice Initializes the account with implementation-specific data.
    /// @param initData Encoded account initialization data.
    function initializeAccount(bytes calldata initData) external payable;
}


/// @title ProxyLib
/// @notice Deploys deterministic Nexus proxy accounts using CREATE3 and owner-derived salts.
/// @dev Existing proxy addresses receive any attached ETH instead of being redeployed.
library ProxyLib {
    /// @notice Thrown when ETH forwarding to an existing proxy fails.
    /// @dev Error selector: `0x6d963f88`
    error EthTransferFailed();

    /// @notice Deploys an initialized deterministic Nexus proxy or funds the existing proxy.
    /// @dev Encodes the Nexus-compatible account initializer call for fresh deployments.
    /// @param implementation The implementation stored in the proxy.
    /// @param owner The owner used to derive the proxy address.
    /// @param initData The data passed to the account initializer.
    /// @return alreadyDeployed Whether the proxy already existed.
    /// @return account The deployed or existing proxy address.
    function deployProxy(address implementation, address owner, bytes memory initData)
        internal
        returns (bool alreadyDeployed, address payable account)
    {
        return
            _deployProxy({implementation: implementation, owner: owner, initializationData: abi.encodeCall(
                INexusAccountInitializer.initializeAccount,
                initData
            )});
    }

    /// @notice Deploys an uninitialized deterministic Nexus proxy or funds the existing proxy.
    /// @dev Used for implementations that intentionally expose no initialization function.
    /// @param implementation The implementation stored in the proxy.
    /// @param owner The owner used to derive the proxy address.
    /// @return alreadyDeployed Whether the proxy already existed.
    /// @return account The deployed or existing proxy address.
    function deployProxyWithoutInitialization(address implementation, address owner)
        internal
        returns (bool alreadyDeployed, address payable account)
    {
        return _deployProxy({implementation: implementation, owner: owner, initializationData: ""});
    }

    /// @notice Predicts the deterministic Nexus proxy address for an owner.
    /// @dev Uses the current contract address as the CREATE3 deployer.
    /// @param owner The owner used to derive the proxy address.
    /// @return predictedAddress The deterministic proxy address.
    function predictProxyAddress(address owner)
        internal
        view
        returns (address payable predictedAddress)
    {
        predictedAddress = payable(CREATE3.predictDeterministicAddress(_getSalt(owner)));
    }

    /// @dev Deploys a proxy if absent. Existing proxies receive any attached ETH.
    function _deployProxy(address implementation, address owner, bytes memory initializationData)
        private
        returns (bool alreadyDeployed, address payable account)
    {
        account = predictProxyAddress(owner);
        alreadyDeployed = account.code.length > 0;
        if (!alreadyDeployed) {
            CREATE3.deployDeterministic(
                msg.value,
                abi.encodePacked(
                    type(NexusProxy).creationCode,
                    abi.encode(implementation, initializationData)
                ),
                _getSalt(owner)
            );
        } else {
            (bool success, ) = account.call{value: msg.value}("");
            require(success, EthTransferFailed());
        }
    }

    /// @dev Converts an owner address into the deterministic CREATE3 salt used for that owner's proxy.
    function _getSalt(address owner) private pure returns (bytes32) {
        return bytes32(bytes20(owner));
    }
}
