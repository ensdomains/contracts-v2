// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

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
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @dev Init-code prefix compiled from `src/hca/HCAProxyInitCode.yul`.
    ///      Regenerate with `forge inspect src/hca/HCAProxyInitCode.yul:HCAProxyInitCode bytecode`.
    bytes internal constant INITIALIZED_HCA_PROXY_INIT_CODE_PREFIX =
        hex"60426100c0818101601481600c395f5190813b1560ac5760145f8381949382947f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc55817fbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b8480a260017f90b772c2cb8a51aa7a8a65fc23543c6d022d5b3f8e2b92eed79fba7eef8293005d601319813803019384910183395af43d5f803e1560a85781905f395ff35b3d5ffd5b50634c9c8ce360e01b5f5260045260245ffdfe3615604057365f80375f8036817f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc545af43d5f803e15603c573d5ff35b3d5ffd5b00";

    /// @dev Init-code prefix compiled from `src/hca/HCAProxyNoInitCode.yul`.
    ///      Regenerate with `forge inspect src/hca/HCAProxyNoInitCode.yul:HCAProxyNoInitCode bytecode`.
    bytes internal constant UNINITIALIZED_HCA_PROXY_INIT_CODE_PREFIX =
        hex"607660426014828201600c395f5191823b156062578282937f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc557fbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b5f80a25f395ff35b82634c9c8ce360e01b5f5260045260245ffdfe3615604057365f80375f8036817f360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc545af43d5f803e15603c573d5ff35b3d5ffd5b00";

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Thrown when ETH forwarding to an existing proxy fails.
    /// @dev Error selector: `0x6d963f88`
    error EthTransferFailed();

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

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

    /// @dev Returns the Yul-derived init-code prefix for initialized proxy deployment.
    function initializedHCAProxyInitCodePrefix() internal pure returns (bytes memory) {
        return INITIALIZED_HCA_PROXY_INIT_CODE_PREFIX;
    }

    /// @dev Returns the Yul-derived init-code prefix for uninitialized proxy deployment.
    function uninitializedHCAProxyInitCodePrefix() internal pure returns (bytes memory) {
        return UNINITIALIZED_HCA_PROXY_INIT_CODE_PREFIX;
    }

    ////////////////////////////////////////////////////////////////////////
    // Private Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Deploys a proxy if absent. Existing proxies receive any attached ETH.
    function _deployProxy(address implementation, address owner, bytes memory initializationData)
        private
        returns (bool alreadyDeployed, address payable account)
    {
        account = predictProxyAddress(owner);
        alreadyDeployed = account.code.length > 0;
        if (!alreadyDeployed) {
            CREATE3.deployDeterministic(msg.value, _proxyInitCode(implementation, initializationData), _getSalt(owner));
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

    /// @dev Builds CREATE3 init code for a constructor-initialized ERC-1967 HCA proxy.
    function _proxyInitCode(address implementation, bytes memory initializationData)
        private
        pure
        returns (bytes memory initCode)
    {
        if (initializationData.length == 0) {
            return bytes.concat(UNINITIALIZED_HCA_PROXY_INIT_CODE_PREFIX, bytes20(implementation));
        }
        return bytes.concat(INITIALIZED_HCA_PROXY_INIT_CODE_PREFIX, bytes20(implementation), initializationData);
    }
}
