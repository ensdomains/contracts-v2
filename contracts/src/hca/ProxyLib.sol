// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

import {ERC1967Utils} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Utils.sol";
import {Proxy} from "@openzeppelin/contracts/proxy/Proxy.sol";
import {CREATE3} from "solady/utils/CREATE3.sol";

/// @notice Minimal initializer interface for HCA account implementations.
/// @dev Interface selector: `0x4b6a1419`
interface IHCAAccountInitializer {
    /// @notice Initializes the account with implementation-specific data.
    /// @param initData Encoded account initialization data.
    function initializeAccount(bytes calldata initData) external payable;
}

/// @title ProxyLib
/// @notice Deploys deterministic HCA proxy accounts using CREATE3 and owner-derived salts.
/// @dev Existing proxy addresses receive any attached ETH instead of being redeployed.
library ProxyLib {
    /// @notice Thrown when ETH forwarding to an existing proxy fails.
    /// @dev Error selector: `0x6d963f88`
    error EthTransferFailed();

    /// @notice Deploys an initialized deterministic HCA proxy or funds the existing proxy.
    /// @dev Encodes the account initializer call for fresh deployments.
    /// @param implementation The implementation stored in the proxy.
    /// @param owner The owner used to derive the proxy address.
    /// @param initData The data passed to the account initializer.
    /// @return alreadyDeployed Whether the proxy already existed.
    /// @return account The deployed or existing proxy address.
    function deployProxy(address implementation, address owner, bytes memory initData)
        internal
        returns (bool alreadyDeployed, address payable account)
    {
        return _deployProxy({
            implementation: implementation,
            owner: owner,
            initializationData: abi.encodeCall(IHCAAccountInitializer.initializeAccount, initData)
        });
    }

    /// @notice Deploys an uninitialized deterministic HCA proxy or funds the existing proxy.
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

    /// @notice Predicts the deterministic HCA proxy address for an owner.
    /// @dev Uses the current contract address as the CREATE3 deployer.
    /// @param owner The owner used to derive the proxy address.
    /// @return predictedAddress The deterministic proxy address.
    function predictProxyAddress(address owner) internal view returns (address payable predictedAddress) {
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
                abi.encodePacked(type(HCAProxy).creationCode, abi.encode(implementation, initializationData)),
                _getSalt(owner)
            );
        } else {
            // solgrid-disable-next-line security/arbitrary-send-eth
            (bool success,) = account.call{value: msg.value}("");
            require(success, EthTransferFailed());
        }
    }

    /// @dev Converts an owner address into the deterministic CREATE3 salt used for that owner's proxy.
    function _getSalt(address owner) private pure returns (bytes32) {
        return bytes32(bytes20(owner));
    }
}

/// @title HCA Proxy
/// @notice ERC-1967 proxy used for deterministic HCA deployments.
/// @dev Sets the same transient initializable flag expected by account implementations that guard proxy initialization.
contract HCAProxy is Proxy {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Transient storage slot used to mark the constructor initialization window.
    bytes32 internal constant INITIALIZABLE_SLOT = 0x90b772c2cb8a51aa7a8a65fc23543c6d022d5b3f8e2b92eed79fba7eef829300;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Deploys the proxy and optionally initializes the implementation.
    /// @param implementation The initial implementation address.
    /// @param data Optional delegatecall data for the implementation.
    constructor(address implementation, bytes memory data) payable {
        _setInitializable();
        ERC1967Utils.upgradeToAndCall(implementation, data);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Allows the proxy to receive ETH.
    receive() external payable {}

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc Proxy
    function _implementation() internal view virtual override returns (address) {
        return ERC1967Utils.getImplementation();
    }

    ////////////////////////////////////////////////////////////////////////
    // Private Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Marks the current transaction as an initialization context for delegatecalled implementations.
    function _setInitializable() private {
        bytes32 slot = INITIALIZABLE_SLOT;
        assembly {
            // Store the initialization flag in transient storage for this transaction.
            tstore(slot, 0x01)
        }
    }
}
