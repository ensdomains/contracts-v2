// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file, contracts-v2/natspec

import {Test} from "forge-std/Test.sol";

import {INexusEventsAndErrors} from "nexus/interfaces/INexusEventsAndErrors.sol";
import {NexusBootstrap} from "nexus/utils/NexusBootstrap.sol";

import {HCA} from "~src/hca/HCA.sol";
import {HCAFactory} from "~src/hca/HCAFactory.sol";
import {HCAInitDataGenerator} from "~src/hca/HCAInitDataGenerator.sol";
import {IHCAFactory} from "~src/hca/IHCAFactory.sol";
import {StaticK1Validator} from "~src/hca/StaticK1Validator.sol";

contract HCAEdgeCasesTest is Test {
    address private _entryPoint;
    address private _owner;
    address private _factoryOwner;

    StaticK1Validator private _validator;
    NexusBootstrap private _bootstrap;
    HCAInitDataGenerator private _initDataGenerator;
    HCAFactory private _factory;
    HCA private _hcaImplementation;

    function setUp() public {
        _entryPoint = makeAddr("entryPoint");
        _owner = makeAddr("owner");
        _factoryOwner = makeAddr("factoryOwner");

        _validator = new StaticK1Validator();

        bytes memory initData = abi.encodePacked(_owner);

        _bootstrap = new NexusBootstrap(address(_validator), initData);

        _initDataGenerator = new HCAInitDataGenerator(address(_bootstrap));
        _factory = new HCAFactory(address(0), _initDataGenerator, _factoryOwner);

        _hcaImplementation = new HCA(
            IHCAFactory(address(_factory)),
            _entryPoint,
            address(_validator),
            initData
        );

        vm.prank(_factoryOwner);
        _factory.setImplementation(address(_hcaImplementation));
    }

    function testFactoryWithDifferentBootstrap() public {
        // Test factory with a different bootstrap configuration
        StaticK1Validator differentValidator = new StaticK1Validator();
        bytes memory differentInitData = abi.encodePacked(makeAddr("differentOwner"));
        NexusBootstrap differentBootstrap = new NexusBootstrap(
            address(differentValidator),
            differentInitData
        );

        HCAInitDataGenerator generator = new HCAInitDataGenerator(address(differentBootstrap));
        HCAFactory differentFactory = new HCAFactory(address(0), generator, _factoryOwner);

        vm.prank(_factoryOwner);
        differentFactory.setImplementation(address(_hcaImplementation));

        // Account creation should work with different bootstrap
        address owner = makeAddr("differentBootstrapOwner");
        address account = differentFactory.createAccount(owner);
        assertTrue(account != address(0), "Account should be created with different bootstrap");
    }

    function testCreateAccountWithZeroAddressOwner() public {
        // Test account creation with zero address owner (should fail during deployment)
        address zeroOwner = address(0);

        // Account creation should revert due to validator rejecting zero address
        vm.expectRevert();
        _factory.createAccount(zeroOwner);
    }

    function testCreateAccountWithMaxUintOwner() public {
        address maxOwner = address(type(uint160).max);
        address account = _factory.createAccount(maxOwner);

        assertTrue(account != address(0), "Account should be created with max uint owner");
        assertEq(_factory.getAccountOwner(account), maxOwner, "Owner should be max uint");
    }

    function testCreateAccountStressTest() public {
        // Create many accounts to test gas limits and storage
        address[] memory accounts = new address[](10);

        for (uint256 i = 0; i < 10; i++) {
            address owner = address(uint160(i + 1000));
            accounts[i] = _factory.createAccount(owner);

            assertTrue(accounts[i] != address(0), "Account should be created");
            assertEq(_factory.getAccountOwner(accounts[i]), owner, "Owner should match");
        }

        // Verify all accounts are unique
        for (uint256 i = 0; i < 10; i++) {
            for (uint256 j = i + 1; j < 10; j++) {
                assertFalse(accounts[i] == accounts[j], "All accounts should be unique");
            }
        }
    }

    function testOwnerAddressCollisionResistance() public {
        // Test with addresses that might cause collisions
        address[] memory testOwners = new address[](5);
        testOwners[0] = address(0x1);
        testOwners[1] = address(0x10);
        testOwners[2] = address(0x100);
        testOwners[3] = address(0x1000);
        testOwners[4] = address(0x10000);

        address[] memory accounts = new address[](5);

        for (uint256 i = 0; i < 5; i++) {
            accounts[i] = _factory.createAccount(testOwners[i]);
        }

        // All should be different
        for (uint256 i = 0; i < 5; i++) {
            for (uint256 j = i + 1; j < 5; j++) {
                assertFalse(
                    accounts[i] == accounts[j],
                    "Accounts with similar owners should be different"
                );
            }
        }
    }

    function testFactoryOwnershipTransfer() public {
        address newFactoryOwner = makeAddr("newFactoryOwner");

        // Transfer ownership (basic Ownable - immediate transfer)
        vm.prank(_factoryOwner);
        _factory.transferOwnership(newFactoryOwner);

        // Old owner should no longer be able to set implementation
        address newImpl = makeAddr("newImpl");
        vm.prank(_factoryOwner);
        vm.expectRevert();
        _factory.setImplementation(newImpl);

        // New owner should be able to set implementation
        vm.prank(newFactoryOwner);
        _factory.setImplementation(newImpl);

        assertEq(
            _factory.getImplementation(),
            newImpl,
            "Implementation should be updated by new owner"
        );
    }

    function testReinitializationAttempt() public {
        address owner = makeAddr("reinitOwner");
        address account = _factory.createAccount(owner);
        HCA hca = HCA(payable(account));

        // Account should be initialized
        assertTrue(hca.isInitialized(), "Account should be initialized");

        // Attempt to reinitialize should fail - expect NexusInitializationFailed because the bootstrap call fails
        bytes memory dummyInitData = abi.encode(address(_bootstrap), "dummy");
        vm.expectRevert(INexusEventsAndErrors.NexusInitializationFailed.selector);
        hca.initializeAccount(dummyInitData);
    }

    function testHCAWithDifferentEntryPoints() public {
        address entryPoint2 = makeAddr("entryPoint2");

        // Create HCA with different entry point
        HCA hca2 = new HCA(
            IHCAFactory(address(_factory)),
            entryPoint2,
            address(_validator),
            abi.encodePacked(_owner)
        );

        // Should work fine
        assertTrue(address(hca2) != address(0), "HCA with different entry point should be created");
    }

    function testFactoryWithInvalidBootstrap() public {
        // Create factory with invalid bootstrap address (zero address)
        HCAInitDataGenerator generator = new HCAInitDataGenerator(address(0));
        HCAFactory badFactory = new HCAFactory(address(0), generator, _factoryOwner);

        vm.prank(_factoryOwner);
        badFactory.setImplementation(address(_hcaImplementation));

        // Creating account should fail during initialization due to invalid bootstrap
        address owner = makeAddr("badOwner");
        vm.expectRevert();
        badFactory.createAccount(owner);
    }

    function testGasOptimizationAccountCreation() public {
        address owner = makeAddr("gasTestOwner");

        uint256 gasBefore = gasleft();
        address account = _factory.createAccount(owner);
        uint256 gasUsed = gasBefore - gasleft();

        assertTrue(account != address(0), "Account should be created");

        // Second creation should use less gas (already deployed)
        gasBefore = gasleft();
        address account2 = _factory.createAccount(owner);
        uint256 gasUsedSecond = gasBefore - gasleft();

        assertEq(account, account2, "Same owner should return same account");
        assertTrue(gasUsedSecond < gasUsed, "Second creation should use less gas");
    }

    function testGeneratorCreationWithComplexBootstrap() public {
        // Test generator with complex bootstrap that has many configurations
        StaticK1Validator complexValidator = new StaticK1Validator();
        bytes memory complexInitData = abi.encodePacked(makeAddr("complexOwner"));
        NexusBootstrap complexBootstrap = new NexusBootstrap(
            address(complexValidator),
            complexInitData
        );

        // This should handle it gracefully
        HCAInitDataGenerator generator = new HCAInitDataGenerator(address(complexBootstrap));
        HCAFactory complexFactory = new HCAFactory(address(0), generator, _factoryOwner);

        vm.prank(_factoryOwner);
        complexFactory.setImplementation(address(_hcaImplementation));

        // Account creation should work
        address owner = makeAddr("complexBootstrapOwner");
        address account = complexFactory.createAccount(owner);
        assertTrue(account != address(0), "Account should be created with complex bootstrap");
    }

    function testFactoryImplementationZeroAddress() public {
        // Test creating accounts when implementation is not set (remains zero)
        HCAInitDataGenerator generator = new HCAInitDataGenerator(address(_bootstrap));
        HCAFactory emptyFactory = new HCAFactory(address(0), generator, _factoryOwner);

        address owner = makeAddr("emptyFactoryOwner");

        // Should fail when trying to create account with zero implementation
        vm.expectRevert();
        emptyFactory.createAccount(owner);
    }
}
