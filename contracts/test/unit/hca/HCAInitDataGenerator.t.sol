// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file, contracts-v2/natspec

import {Test} from "forge-std/Test.sol";

import {CALLTYPE_SINGLE} from "nexus/lib/ModeLib.sol";
import {
    NexusBootstrap,
    BootstrapConfig,
    BootstrapPreValidationHookConfig
} from "nexus/utils/NexusBootstrap.sol";

import {HCAInitDataGenerator} from "~src/hca/HCAInitDataGenerator.sol";
import {IInitDataGenerator} from "~src/hca/IInitDataGenerator.sol";
import {StaticK1Validator} from "~src/hca/StaticK1Validator.sol";

contract HCAInitDataGeneratorTest is Test {
    HCAInitDataGenerator private _generator;
    StaticK1Validator private _validator;
    NexusBootstrap private _bootstrap;

    function setUp() public {
        _validator = new StaticK1Validator();

        bytes memory initData = abi.encodePacked(address(0xBEEF)); // placeholder
        _bootstrap = new NexusBootstrap(address(_validator), initData);

        _generator = new HCAInitDataGenerator(address(_bootstrap));
    }

    function testImplementsInterface() public {
        // Test that the generator correctly implements the interface by calling it successfully with valid data
        address testOwner = makeAddr("interfaceTest");

        bytes memory result = _generator.generateInitData(testOwner);

        // If we get here without reverting, the interface is properly implemented
        assertTrue(result.length > 0, "Interface is properly implemented and returns data");
    }

    function testGenerateInitDataWithValidOwner() public {
        address owner = makeAddr("testOwner");

        bytes memory generatedData = _generator.generateInitData(owner);

        // Verify the generated data has correct structure
        (address bootstrap, bytes memory bootstrapCall) = abi.decode(
            generatedData,
            (address, bytes)
        );

        assertEq(bootstrap, address(_bootstrap), "Bootstrap address should match");
        assertTrue(bootstrapCall.length > 0, "Bootstrap call should not be empty");

        // Verify the bootstrap call contains the correct owner
        // The owner should be encoded in the first parameter (validator data)
        bytes memory paramsData = new bytes(bootstrapCall.length - 4);
        for (uint256 i = 0; i < bootstrapCall.length - 4; i++) {
            paramsData[i] = bootstrapCall[i + 4];
        }

        (bytes memory validatorData, , , , , ) = abi.decode(
            paramsData,
            (
                bytes,
                BootstrapConfig[],
                BootstrapConfig[],
                BootstrapConfig,
                BootstrapConfig[],
                BootstrapPreValidationHookConfig[]
            )
        );

        address decodedOwner = address(bytes20(validatorData));
        assertEq(decodedOwner, owner, "Decoded owner should match input owner");
    }

    function testGenerateInitDataWithZeroOwner() public {
        address owner = address(0);

        bytes memory generatedData = _generator.generateInitData(owner);

        // Should still work with zero address
        (address bootstrap, bytes memory bootstrapCall) = abi.decode(
            generatedData,
            (address, bytes)
        );

        assertEq(bootstrap, address(_bootstrap), "Bootstrap address should match");
        assertTrue(bootstrapCall.length > 0, "Bootstrap call should not be empty");
    }

    function testGenerateInitDataWithDifferentOwners() public {
        address owner1 = makeAddr("owner1");
        address owner2 = makeAddr("owner2");

        bytes memory data1 = _generator.generateInitData(owner1);
        bytes memory data2 = _generator.generateInitData(owner2);

        // Data should be different for different owners
        assertFalse(
            keccak256(data1) == keccak256(data2),
            "Generated data should be different for different owners"
        );

        // But bootstrap addresses should be the same
        (address bootstrap1, ) = abi.decode(data1, (address, bytes));
        (address bootstrap2, ) = abi.decode(data2, (address, bytes));

        assertEq(bootstrap1, bootstrap2, "Bootstrap addresses should be the same");
    }

    function testGenerateInitDataPreservesStructure() public {
        address owner = makeAddr("structureTestOwner");

        bytes memory generatedData = _generator.generateInitData(owner);
        (address bootstrap, bytes memory bootstrapCall) = abi.decode(
            generatedData,
            (address, bytes)
        );

        // Decode the bootstrap call parameters
        bytes memory paramsData = new bytes(bootstrapCall.length - 4);
        for (uint256 i = 0; i < bootstrapCall.length - 4; i++) {
            paramsData[i] = bootstrapCall[i + 4];
        }

        (
            bytes memory validatorData,
            BootstrapConfig[] memory validators,
            BootstrapConfig[] memory executors,
            BootstrapConfig memory hook,
            BootstrapConfig[] memory fallbacks,
            BootstrapPreValidationHookConfig[] memory preValidationHooks
        ) = abi.decode(
                paramsData,
                (
                    bytes,
                    BootstrapConfig[],
                    BootstrapConfig[],
                    BootstrapConfig,
                    BootstrapConfig[],
                    BootstrapPreValidationHookConfig[]
                )
            );

        // Verify structure is preserved
        assertEq(validators.length, 0, "Validators array should be empty");
        assertEq(executors.length, 0, "Executors array should be empty");
        assertEq(hook.module, address(0), "Hook should be zero address");
        assertEq(fallbacks.length, 3, "Should have 3 fallback handlers");
        assertEq(preValidationHooks.length, 0, "PreValidation hooks should be empty");

        // Verify fallback handlers are preserved
        assertEq(
            fallbacks[0].data,
            abi.encodePacked(bytes4(0x150b7a02), CALLTYPE_SINGLE),
            "First fallback data should match"
        );
        assertEq(
            fallbacks[1].data,
            abi.encodePacked(bytes4(0xf23a6e61), CALLTYPE_SINGLE),
            "Second fallback data should match"
        );
        assertEq(
            fallbacks[2].data,
            abi.encodePacked(bytes4(0xbc197c81), CALLTYPE_SINGLE),
            "Third fallback data should match"
        );
    }

    function testGenerateInitDataWithZeroAddress() public {
        address owner = address(0);

        // Should not revert with zero address (though deployment might fail later)
        bytes memory generatedData = _generator.generateInitData(owner);
        assertTrue(generatedData.length > 0, "Should generate data even with zero address");
    }

    function testGenerateInitDataConsistency() public {
        address owner = makeAddr("consistencyOwner");

        // Generate the same data multiple times
        bytes memory data1 = _generator.generateInitData(owner);
        bytes memory data2 = _generator.generateInitData(owner);
        bytes memory data3 = _generator.generateInitData(owner);

        // Should be identical every time
        assertEq(keccak256(data1), keccak256(data2), "Data should be consistent across calls");
        assertEq(keccak256(data2), keccak256(data3), "Data should be consistent across calls");
    }

    function testGenerateInitDataGasUsage() public {
        address owner = makeAddr("gasTestOwner");

        uint256 gasBefore = gasleft();
        bytes memory generatedData = _generator.generateInitData(owner);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(generatedData.length > 0, "Should generate data");
        assertTrue(gasUsed < 500000, "Should use reasonable amount of gas"); // Arbitrary reasonable limit
    }

    function testGenerateInitDataWithMaxOwner() public {
        address owner = address(type(uint160).max);

        bytes memory generatedData = _generator.generateInitData(owner);

        // Should handle max address
        (address bootstrap, bytes memory bootstrapCall) = abi.decode(
            generatedData,
            (address, bytes)
        );

        assertEq(bootstrap, address(_bootstrap), "Bootstrap address should match");
        assertTrue(bootstrapCall.length > 0, "Bootstrap call should not be empty");
    }

    function testGenerateInitDataPreservesBootstrapCallStructure() public {
        address owner = makeAddr("callStructureOwner");

        bytes memory generatedData = _generator.generateInitData(owner);
        (address bootstrap, bytes memory bootstrapCall) = abi.decode(
            generatedData,
            (address, bytes)
        );

        // Verify the bootstrap call starts with the correct function selector
        bytes4 expectedSelector = NexusBootstrap
            .initNexusWithDefaultValidatorAndOtherModulesNoRegistry
            .selector;
        bytes4 actualSelector = bytes4(bootstrapCall);

        assertEq(actualSelector, expectedSelector, "Function selector should be preserved");
    }
}
