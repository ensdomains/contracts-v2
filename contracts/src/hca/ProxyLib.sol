// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {NexusProxy} from "nexus/utils/NexusProxy.sol";
import {INexus} from "nexus/interfaces/INexus.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

/// @title ProxyLib
/// @notice A library for deploying NexusProxy contracts
library ProxyLib {
    /// @notice Error thrown when ETH transfer fails.
    error EthTransferFailed();

    function deployProxy(
        address implementation,
        address owner_,
        bytes memory initData
    ) internal returns (bool alreadyDeployed, address payable account) {
        // Check if the contract is already deployed
        account = predictProxyAddress(owner_);
        alreadyDeployed = account.code.length > 0;
        // Deploy a new contract if it is not already deployed
        if (!alreadyDeployed) {
            // Deploy the contract
            CREATE3.deployDeterministic(
                msg.value,
                abi.encodePacked(
                    type(NexusProxy).creationCode,
                    abi.encode(
                        implementation,
                        abi.encodeCall(INexus.initializeAccount, initData)
                    )
                ),
                _getSalt(owner_)
            );
        } else {
            // Forward the value to the existing contract
            (bool success, ) = account.call{value: msg.value}("");
            require(success, EthTransferFailed());
        }
    }

    function predictProxyAddress(
        address owner_
    ) internal view returns (address payable predictedAddress) {
        return payable(CREATE3.predictDeterministicAddress(_getSalt(owner_)));
    }

    function _getSalt(address owner_) internal pure returns (bytes32) {
        return bytes32(bytes20(owner_));
    }
}
