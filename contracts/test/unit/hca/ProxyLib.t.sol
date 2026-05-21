// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {stdJson} from "forge-std/StdJson.sol";
import {Test, Vm} from "forge-std/Test.sol";

import {ProxyLib} from "~src/hca/ProxyLib.sol";

/// @title ProxyLibHarness
/// @notice Exposes internal proxy deployment helpers for unit tests.
contract ProxyLibHarness {
    /// @notice Deploys an initialized proxy through ProxyLib.
    /// @param implementation The implementation stored in the proxy.
    /// @param owner The owner used to derive the deterministic proxy salt.
    /// @param initData Implementation-specific initialization data.
    /// @return alreadyDeployed Whether the proxy already existed.
    /// @return account The deployed or existing proxy address.
    function deployProxy(address implementation, address owner, bytes memory initData)
        external
        payable
        returns (bool alreadyDeployed, address payable account)
    {
        return ProxyLib.deployProxy(implementation, owner, initData);
    }

    /// @notice Deploys an uninitialized proxy through ProxyLib.
    /// @param implementation The implementation stored in the proxy.
    /// @param owner The owner used to derive the deterministic proxy salt.
    /// @return alreadyDeployed Whether the proxy already existed.
    /// @return account The deployed or existing proxy address.
    function deployProxyWithoutInitialization(address implementation, address owner)
        external
        payable
        returns (bool alreadyDeployed, address payable account)
    {
        return ProxyLib.deployProxyWithoutInitialization(implementation, owner);
    }

    /// @notice Predicts the proxy address for an owner.
    /// @param owner The owner used to derive the deterministic proxy salt.
    /// @return predictedAddress The deterministic proxy address.
    function predictProxyAddress(address owner) external view returns (address payable predictedAddress) {
        return ProxyLib.predictProxyAddress(owner);
    }

    /// @notice Returns the initialized proxy init-code prefix embedded in ProxyLib.
    /// @return initCodePrefix The Yul-derived init-code prefix.
    function initializedHCAProxyInitCodePrefix() external pure returns (bytes memory initCodePrefix) {
        return ProxyLib.initializedHCAProxyInitCodePrefix();
    }

    /// @notice Returns the uninitialized proxy init-code prefix embedded in ProxyLib.
    /// @return initCodePrefix The Yul-derived init-code prefix.
    function uninitializedHCAProxyInitCodePrefix() external pure returns (bytes memory initCodePrefix) {
        return ProxyLib.uninitializedHCAProxyInitCodePrefix();
    }
}

/// @title MockHCAProxyImplementation
/// @notice Implementation used to verify HCA proxy initialization and delegation.
contract MockHCAProxyImplementation {
    /// @notice Emitted when the account initializer is called.
    /// @param initDataHash Hash of the supplied initialization data.
    /// @param value ETH value observed during initialization.
    /// @param sender Sender observed during initialization.
    /// @param initializable Whether the proxy creation code exposed constructor initialization.
    event Initialized(bytes32 initDataHash, uint256 value, address sender, bool initializable);

    /// @dev Slot used by the account implementation to detect constructor initialization.
    bytes32 internal constant INITIALIZABLE_STORAGE =
        0x90b772c2cb8a51aa7a8a65fc23543c6d022d5b3f8e2b92eed79fba7eef829300;

    /// @notice Last observed initialization data hash.
    bytes32 public lastInitDataHash;

    /// @notice Last observed initialization value.
    uint256 public lastInitValue;

    /// @notice Last observed initializer sender.
    address public lastInitSender;

    /// @notice Last observed constructor-initialization flag.
    bool public lastInitializable;

    /// @notice Value written through a delegated proxy call.
    uint256 public value;

    /// @notice Initializes the proxy account with implementation-specific data.
    /// @param initData Encoded account initialization data.
    function initializeAccount(bytes calldata initData) external payable {
        bool initializable;
        assembly {
            // Read the transient constructor-initialization flag written by the proxy creation code.
            initializable := tload(INITIALIZABLE_STORAGE)
        }

        lastInitDataHash = keccak256(initData);
        lastInitValue = msg.value;
        lastInitSender = msg.sender;
        lastInitializable = initializable;

        emit Initialized(keccak256(initData), msg.value, msg.sender, initializable);
    }

    /// @notice Writes a value through a delegated proxy call.
    /// @param newValue The value to store.
    function setValue(uint256 newValue) external {
        value = newValue;
    }
}

/// @title ProxyLibTest
/// @notice Tests deterministic HCA proxy deployment through ProxyLib.
contract ProxyLibTest is Test {
    using stdJson for string;

    /// @dev ERC-1967 implementation slot.
    bytes32 internal constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @dev ERC-1967 Upgraded(address) event topic.
    bytes32 internal constant UPGRADED_TOPIC = 0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b;

    ProxyLibHarness harness;
    MockHCAProxyImplementation implementation;

    address owner = address(0x1111);

    function setUp() public {
        harness = new ProxyLibHarness();
        implementation = new MockHCAProxyImplementation();
    }

    function test_initializedPrefix_matchesCompiledYul() public view {
        string memory artifact = vm.readFile("out/HCAProxyInitCode.yul/HCAProxyInitCode.json");

        assertEq(
            harness.initializedHCAProxyInitCodePrefix(),
            artifact.readBytes(".bytecode.object"),
            "initialized yul bytecode"
        );
    }

    function test_uninitializedPrefix_matchesCompiledYul() public view {
        string memory artifact = vm.readFile("out/HCAProxyNoInitCode.yul/HCAProxyNoInitCode.json");

        assertEq(
            harness.uninitializedHCAProxyInitCodePrefix(),
            artifact.readBytes(".bytecode.object"),
            "uninitialized yul bytecode"
        );
    }

    function test_deployProxy_deploysPredictedCreate3Proxy() public {
        bytes memory initData = abi.encode(owner, "records");
        address payable predicted = harness.predictProxyAddress(owner);
        vm.deal(address(this), 1 ether);

        vm.recordLogs();
        (bool alreadyDeployed, address payable account) =
            harness.deployProxy{value: 1 ether}(address(implementation), owner, initData);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(alreadyDeployed);
        assertEq(account, predicted);
        assertEq(account.balance, 1 ether);
        assertEq(_implementationOf(account), address(implementation));
        assertEq(MockHCAProxyImplementation(account).lastInitDataHash(), keccak256(initData));
        assertEq(MockHCAProxyImplementation(account).lastInitValue(), 1 ether);
        assertTrue(MockHCAProxyImplementation(account).lastInitializable());
        _assertUpgradedLog(logs, account, address(implementation));
    }

    function test_deployProxyWithoutInitialization_deploysPredictedCreate3Proxy() public {
        address payable predicted = harness.predictProxyAddress(owner);

        vm.recordLogs();
        (bool alreadyDeployed, address payable account) =
            harness.deployProxyWithoutInitialization(address(implementation), owner);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertFalse(alreadyDeployed);
        assertEq(account, predicted);
        assertEq(_implementationOf(account), address(implementation));
        assertEq(MockHCAProxyImplementation(account).lastInitDataHash(), bytes32(0));
        _assertUpgradedLog(logs, account, address(implementation));
    }

    function test_deployProxy_forwardsEthWhenProxyAlreadyExists() public {
        vm.deal(address(this), 1 ether);
        bytes memory initData = abi.encode(owner);
        (, address payable account) = harness.deployProxy(address(implementation), owner, initData);

        (bool alreadyDeployed, address payable existingAccount) =
            harness.deployProxy{value: 1 ether}(address(implementation), owner, initData);

        assertTrue(alreadyDeployed);
        assertEq(existingAccount, account);
        assertEq(account.balance, 1 ether);
    }

    function test_delegatesRuntimeCallsToImplementation() public {
        (, address payable account) = harness.deployProxyWithoutInitialization(address(implementation), owner);

        MockHCAProxyImplementation(account).setValue(42);

        assertEq(MockHCAProxyImplementation(account).value(), 42);
    }

    function _implementationOf(address account) private view returns (address implementation_) {
        implementation_ = address(uint160(uint256(vm.load(account, IMPLEMENTATION_SLOT))));
    }

    function _assertUpgradedLog(Vm.Log[] memory logs, address emitter, address implementation_) private pure {
        bool found;
        bytes32 implementationTopic = bytes32(uint256(uint160(implementation_)));
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == emitter && logs[i].topics.length == 2 && logs[i].topics[0] == UPGRADED_TOPIC
                    && logs[i].topics[1] == implementationTopic && logs[i].data.length == 0
            ) {
                found = true;
                break;
            }
        }

        assertTrue(found, "missing Upgraded log");
    }
}
