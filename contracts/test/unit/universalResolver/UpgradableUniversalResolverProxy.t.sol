// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {OffchainLookup} from "@ens/contracts/ccipRead/EIP3668.sol";
import {GatewayProvider} from "@ens/contracts/ccipRead/GatewayProvider.sol";
import {ENS} from "@ens/contracts/registry/ENS.sol";
import {IUniversalResolver} from "@ens/contracts/universalResolver/IUniversalResolver.sol";
import {
    UniversalResolver as UniversalResolverV1
} from "@ens/contracts/universalResolver/UniversalResolver.sol";
import {BytesUtils} from "@ens/contracts/utils/BytesUtils.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {UniversalResolverV2} from "~src/universalResolver/UniversalResolverV2.sol";
import {
    UpgradableUniversalResolverProxy
} from "~src/universalResolver/UpgradableUniversalResolverProxy.sol";

contract ProxyTest is Test {
    address constant ADMIN = address(0x123);
    address constant USER = address(0x456);
    address constant STRANGER = address(0x789);

    UpgradableUniversalResolverProxy proxy;
    UniversalResolverV1 urV1;
    UniversalResolverV2 urV2;

    // Mock data for tests
    bytes dnsEncodedName = hex"0365746800"; // "eth"
    bytes mockData = hex"12345678";
    address mockResolver = address(0xabc);

    event Upgraded(address indexed implementation);
    event AdminChanged(address indexed previousAdmin, address indexed newAdmin);
    event AdminRemoved(address indexed admin);

    function setUp() public {
        vm.startPrank(ADMIN);

        string[] memory gatewayUrls = new string[](1);
        gatewayUrls[0] = "http://universal-offchain-resolver.local";
        GatewayProvider batchGatewayProvider = new GatewayProvider(address(this), gatewayUrls);

        // Deploy the implementations
        urV1 = new UniversalResolverV1(address(0), ENS(address(this)), batchGatewayProvider);
        urV2 = new UniversalResolverV2(IRegistry(address(0)), batchGatewayProvider);

        // Deploy the proxy with V1 implementation
        proxy = new UpgradableUniversalResolverProxy(ADMIN, address(urV1));

        vm.stopPrank();
    }

    /////// Mock ReverseClaimer ///////
    function claim(address) external pure returns (bytes32) {}
    function owner(bytes32) external view returns (address) {
        return address(this);
    }

    /////// Core Functionality Tests ///////

    function test_InitialState() public view {
        assertEq(proxy.admin(), ADMIN);
        assertEq(proxy.implementation(), address(urV1));
    }

    /////// Admin Tests ///////

    function test_SuccessfulUpgrade() public {
        // Expect the Upgraded event to be emitted
        vm.expectEmit(true, true, true, true);
        emit Upgraded(address(urV2));

        // Perform the upgrade
        vm.prank(ADMIN);
        proxy.upgradeTo(address(urV2));

        // Verify the implementation has been set
        assertEq(proxy.implementation(), address(urV2));
        // Admin should remain unchanged
        assertEq(proxy.admin(), ADMIN);
    }

    function test_RenounceAdmin() public {
        // Expect AdminRemoved event
        vm.expectEmit(true, true, true, true);
        emit AdminRemoved(ADMIN);

        // Perform admin renouncement
        vm.prank(ADMIN);
        proxy.renounceAdmin();

        // Verify admin was removed
        assertEq(proxy.admin(), address(0));
    }

    function test_UnauthorizedUpgrade() public {
        // Try to upgrade from non-admin account
        vm.prank(STRANGER);
        vm.expectRevert(UpgradableUniversalResolverProxy.CallerNotAdmin.selector);
        proxy.upgradeTo(address(urV2));
    }

    function test_UpgradeToInvalidImplementation() public {
        // Try to upgrade to a non-contract address
        vm.prank(ADMIN);
        vm.expectRevert(UpgradableUniversalResolverProxy.InvalidImplementation.selector);
        proxy.upgradeTo(address(0));

        // Try to upgrade to the same implementation
        vm.prank(ADMIN);
        vm.expectRevert(UpgradableUniversalResolverProxy.SameImplementation.selector);
        proxy.upgradeTo(address(urV1));
    }

    /////// Forwarding Tests ///////

    function test_ForwardingSingleCall() public {
        // Test with a mock implementation that returns predefined values
        MockCompleteImplementation mockImpl = new MockCompleteImplementation();

        // Create a new proxy with the mock implementation
        vm.prank(ADMIN);
        UpgradableUniversalResolverProxy testProxy = new UpgradableUniversalResolverProxy(
            ADMIN,
            address(mockImpl)
        );

        // Create calldata for resolve method
        bytes memory callData = abi.encodeWithSignature(
            "resolve(bytes,bytes)",
            dnsEncodedName,
            mockData
        );

        // Make the call through the proxy
        (bool success, bytes memory result) = address(testProxy).call(callData);

        // Verify the call was successful
        assertTrue(success);

        // Decode the result to verify it matches expectations
        (bytes memory returnedData, address returnedResolver) = abi.decode(
            result,
            (bytes, address)
        );
        assertEq(returnedData, bytes.concat(dnsEncodedName, mockData));
        assertEq(returnedResolver, mockResolver);
    }

    function test_ForwardingReverseCall() public {
        // Test with a mock implementation that returns predefined values
        MockCompleteImplementation mockImpl = new MockCompleteImplementation();

        // Create a new proxy with the mock implementation
        vm.prank(ADMIN);
        UpgradableUniversalResolverProxy testProxy = new UpgradableUniversalResolverProxy(
            ADMIN,
            address(mockImpl)
        );

        // Create calldata for reverse method
        bytes memory callData = abi.encodeWithSignature(
            "reverse(bytes,uint256)",
            dnsEncodedName,
            uint256(60)
        );

        // Make the call through the proxy
        (bool success, bytes memory result) = address(testProxy).call(callData);

        // Verify the call was successful
        assertTrue(success);

        // Decode the result to verify it matches expectations
        (string memory name, address resolver, address reverseResolver) = abi.decode(
            result,
            (string, address, address)
        );
        assertEq(name, "test.eth");
        assertEq(resolver, mockResolver);
        assertEq(reverseResolver, address(mockImpl));
    }

    /////// CCIP-Read Tests ///////

    function test_CCIPReadForwarding() public {
        // Create a mock implementation that reverts with OffchainLookup
        MockCCIPReadImplementation mockCCIPImpl = new MockCCIPReadImplementation();

        // Create a new proxy using the mock implementation
        vm.prank(ADMIN);
        UpgradableUniversalResolverProxy ccipProxy = new UpgradableUniversalResolverProxy(
            ADMIN,
            address(mockCCIPImpl)
        );

        // Create calldata for resolve method
        bytes memory callData = abi.encodeWithSignature(
            "resolve(bytes,bytes)",
            dnsEncodedName,
            mockData
        );

        // Make the call and catch the revert data
        (bool success, bytes memory returnData) = address(ccipProxy).call(callData);

        // First assertion: the call should revert
        assertFalse(success);

        // Second assertion: the revert should be an OffchainLookup error
        assertEq(bytes4(returnData), OffchainLookup.selector);

        // Parse the OffchainLookup parameters
        bytes memory errorData = BytesUtils.substring(returnData, 4, returnData.length - 4);
        (
            address sender,
            string[] memory urls,
            bytes memory ccipCallData,
            bytes4 callbackFunction,
            bytes memory extraData
        ) = abi.decode(errorData, (address, string[], bytes, bytes4, bytes));

        // Third assertion: the sender should be the proxy address, not the implementation
        assertEq(sender, address(ccipProxy));

        // Fourth assertion: other parameters should match the original
        assertEq(urls.length, mockCCIPImpl.getUrls().length);
        assertEq(urls[0], mockCCIPImpl.getUrls()[0]);
        assertEq(ccipCallData, mockCCIPImpl.getCallData());
        assertEq(callbackFunction, mockCCIPImpl.getCallbackFunction());
        assertEq(extraData, mockCCIPImpl.getExtraData());
    }

    function test_CCIPReadWithDifferentSender() public {
        // Create a mock implementation that reverts with OffchainLookup but with a different sender
        MockCCIPReadWithDifferentSender mockDiffSenderImpl = new MockCCIPReadWithDifferentSender();

        // Create a new proxy using the mock implementation
        vm.prank(ADMIN);
        UpgradableUniversalResolverProxy senderProxy = new UpgradableUniversalResolverProxy(
            ADMIN,
            address(mockDiffSenderImpl)
        );

        // Create calldata for resolve method
        bytes memory callData = abi.encodeWithSignature(
            "resolve(bytes,bytes)",
            dnsEncodedName,
            mockData
        );

        // Make the call
        (bool success, bytes memory result) = address(senderProxy).call(callData);

        // Verify the call failed
        assertFalse(success);

        // Check that it failed with OffchainLookup
        assertEq(bytes4(result), OffchainLookup.selector);

        // Decode the OffchainLookup error to verify sender was NOT replaced
        // Skip the selector (first 4 bytes)
        bytes memory errorData = BytesUtils.substring(result, 4, result.length - 4);
        (address sender, , , , ) = abi.decode(errorData, (address, string[], bytes, bytes4, bytes));

        // Verify the sender is the different sender (not modified by proxy)
        address differentSender = address(0xbeef);
        assertEq(sender, differentSender);
    }

    function test_NonCCIPReadErrorForwarding() public {
        // Create a mock implementation that reverts with a custom error
        MockRevertingImplementation mockRevertImpl = new MockRevertingImplementation();

        // Create a new proxy using the mock implementation
        vm.prank(ADMIN);
        UpgradableUniversalResolverProxy revertProxy = new UpgradableUniversalResolverProxy(
            ADMIN,
            address(mockRevertImpl)
        );

        // Create calldata for resolve method
        bytes memory callData = abi.encodeWithSignature(
            "resolve(bytes,bytes)",
            dnsEncodedName,
            mockData
        );

        // Make the call and capture the result
        (bool success, bytes memory result) = address(revertProxy).call(callData);

        // Verify that the call reverted
        assertFalse(success);

        // Verify that the revert was due to our custom error
        assertEq(bytes4(result), MockRevertingImplementation.CustomError.selector);
    }

    /////// Fallback Tests ///////

    function test_FallbackWithValidCall() public {
        // Test with a mock implementation that returns predefined values
        MockCompleteImplementation mockImpl = new MockCompleteImplementation();

        // Create a new proxy with the mock implementation
        vm.prank(ADMIN);
        UpgradableUniversalResolverProxy testProxy = new UpgradableUniversalResolverProxy(
            ADMIN,
            address(mockImpl)
        );

        // Create calldata for a method that is properly implemented in mock
        bytes memory callData = abi.encodeWithSignature(
            "resolve(bytes,bytes)",
            dnsEncodedName,
            mockData
        );

        // Make the call through the fallback
        (bool success, bytes memory result) = address(testProxy).call(callData);

        // Verify the call was successful
        assertTrue(success);
        // Can't easily verify the exact result, but can check it's not empty
        assertTrue(result.length > 0);
    }

    function test_FallbackWithInvalidCall() public {
        // Create calldata for a non-existent method
        bytes memory callData = abi.encodeWithSignature("nonExistentFunction()");

        // The call should fail
        (bool success, ) = address(proxy).call(callData);
        assertFalse(success);
    }
}

// Base contract for mocks to implement common functionality
abstract contract UniversalResolverMockBase is IUniversalResolver {
    function supportsInterface(bytes4 interfaceId) external pure virtual returns (bool) {
        return
            interfaceId == type(IUniversalResolver).interfaceId ||
            interfaceId == type(IERC165).interfaceId;
    }

    // Default implementation for all methods
    function resolve(
        bytes calldata,
        bytes calldata
    ) external view virtual returns (bytes memory, address) {
        return (bytes(""), address(0));
    }

    function findResolver(
        bytes calldata
    ) external view virtual returns (address, bytes32, uint256) {
        return (address(0), bytes32(0), 0);
    }

    function reverse(
        bytes calldata,
        uint256
    ) external view virtual returns (string memory, address, address) {
        return ("", address(0), address(0));
    }
}

// Mock with full implementation returning expected values
contract MockCompleteImplementation is UniversalResolverMockBase {
    address public constant MOCK_RESOLVER = address(0xabc);
    bytes32 public constant MOCK_NAMEHASH = bytes32(uint256(0x1));
    uint256 public constant MOCK_OFFSET = 0;

    // Add this method to handle the resolveCallback
    function resolveCallback(
        bytes calldata response,
        bytes calldata extraData
    ) external pure returns (bytes memory, address) {
        return (bytes.concat(response, extraData), MOCK_RESOLVER);
    }

    function resolve(
        bytes calldata name,
        bytes calldata data
    ) external pure override returns (bytes memory, address) {
        return (bytes.concat(name, data), MOCK_RESOLVER);
    }

    function findResolver(
        bytes calldata
    ) external pure override returns (address, bytes32, uint256) {
        return (MOCK_RESOLVER, MOCK_NAMEHASH, MOCK_OFFSET);
    }

    function reverse(
        bytes calldata,
        uint256
    ) external view override returns (string memory, address, address) {
        return ("test.eth", MOCK_RESOLVER, address(this));
    }
}

// Mock that reverts with CCIP-Read
contract MockCCIPReadImplementation is UniversalResolverMockBase {
    string[] private urls = new string[](1);
    bytes private callData = hex"1234";
    bytes4 private callbackFunction = bytes4(keccak256("mockCallback(bytes,bytes)"));
    bytes private extraData = hex"5678";

    constructor() {
        urls[0] = "https://mockgateway.com";
    }

    function getUrls() external view returns (string[] memory) {
        return urls;
    }

    function getCallData() external view returns (bytes memory) {
        return callData;
    }

    function getCallbackFunction() external view returns (bytes4) {
        return callbackFunction;
    }

    function getExtraData() external view returns (bytes memory) {
        return extraData;
    }

    function resolve(
        bytes calldata,
        bytes calldata
    ) external view override returns (bytes memory, address) {
        // Revert with OffchainLookup
        revert OffchainLookup(address(this), urls, callData, callbackFunction, extraData);
    }
}

// Mock that reverts with CCIP-Read but uses a different sender
contract MockCCIPReadWithDifferentSender is UniversalResolverMockBase {
    address private differentSender = address(0xbeef);
    string[] private urls = new string[](1);
    bytes private callData = hex"1234";
    bytes4 private callbackFunction = bytes4(keccak256("mockCallback(bytes,bytes)"));
    bytes private extraData = hex"5678";

    constructor() {
        urls[0] = "https://mockgateway.com";
    }

    function getUrls() external view returns (string[] memory) {
        return urls;
    }

    function getCallData() external view returns (bytes memory) {
        return callData;
    }

    function getCallbackFunction() external view returns (bytes4) {
        return callbackFunction;
    }

    function getExtraData() external view returns (bytes memory) {
        return extraData;
    }

    function resolve(
        bytes calldata,
        bytes calldata
    ) external view override returns (bytes memory, address) {
        // Revert with OffchainLookup using a different sender
        revert OffchainLookup(differentSender, urls, callData, callbackFunction, extraData);
    }
}

// Mock that reverts with a custom error
contract MockRevertingImplementation is UniversalResolverMockBase {
    error CustomError();

    function resolve(
        bytes calldata,
        bytes calldata
    ) external pure override returns (bytes memory, address) {
        revert CustomError();
    }
}
