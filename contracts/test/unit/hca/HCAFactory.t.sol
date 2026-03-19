// SPDX-License-Identifier: MIT
pragma solidity ^0.8.27;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file, contracts-v2/natspec

import {Test} from "forge-std/Test.sol";

import {NexusBootstrap} from "nexus/utils/NexusBootstrap.sol";

import {HCA} from "~src/hca/HCA.sol";
import {HCAFactory} from "~src/hca/HCAFactory.sol";
import {HCAInitDataGenerator} from "~src/hca/HCAInitDataGenerator.sol";
import {IHCAFactory} from "~src/hca/IHCAFactory.sol";
import {StaticK1Validator} from "~src/hca/StaticK1Validator.sol";

contract HCAFactoryTest is Test {
    address private _entryPoint;
    address private _owner;
    address private _factoryOwner;
    address private _hcaOwner;

    StaticK1Validator private _validator;
    NexusBootstrap private _bootstrap;
    HCAInitDataGenerator private _initDataGenerator;
    HCAFactory private _factory;
    HCA private _hcaImplementation;
    HCA private _hca;

    function setUp() public {
        _entryPoint = makeAddr("entryPoint");
        _owner = makeAddr("owner");
        _factoryOwner = makeAddr("factoryOwner");
        _hcaOwner = makeAddr("hcaOwner");

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

        _hca = HCA(payable(_factory.createAccount(_hcaOwner)));
    }

    function testCreateAccountSuccessfully() public {
        address newOwner = makeAddr("newOwner");
        address account = _factory.createAccount(newOwner);

        // Verify account was created
        assertFalse(account == address(0), "Account address should not be zero");

        // Verify account has correct owner
        address retrievedOwner = _factory.getAccountOwner(account);
        assertEq(retrievedOwner, newOwner, "Account owner should match");

        // Verify HCA getOwner also returns correct owner
        HCA hca = HCA(payable(account));
        assertEq(hca.getOwner(), newOwner, "HCA getOwner should return correct owner");
    }

    function testCreateAccountDeterministic() public {
        address owner1 = makeAddr("owner1");

        // Predict address before creation
        address predictedAddr = _factory.computeAccountAddress(owner1);

        // Create account
        address actualAddr = _factory.createAccount(owner1);

        // Verify addresses match
        assertEq(actualAddr, predictedAddr, "Created address should match predicted address");
    }

    function testCreateAccountIdempotent() public {
        address owner1 = makeAddr("owner1");

        // Create account first time
        address account1 = _factory.createAccount(owner1);

        // Create same account again
        address account2 = _factory.createAccount(owner1);

        // Should return same address
        assertEq(account1, account2, "Creating same account twice should return same address");
    }

    function testMultipleAccountsWithDifferentOwners() public {
        address owner1 = makeAddr("owner1");
        address owner2 = makeAddr("owner2");
        address owner3 = makeAddr("owner3");

        // Create multiple accounts
        address account1 = _factory.createAccount(owner1);
        address account2 = _factory.createAccount(owner2);
        address account3 = _factory.createAccount(owner3);

        // All should be different addresses
        assertFalse(account1 == account2, "Different owners should have different accounts");
        assertFalse(account2 == account3, "Different owners should have different accounts");
        assertFalse(account1 == account3, "Different owners should have different accounts");

        // Each should have correct owner
        assertEq(_factory.getAccountOwner(account1), owner1, "Account1 owner mismatch");
        assertEq(_factory.getAccountOwner(account2), owner2, "Account2 owner mismatch");
        assertEq(_factory.getAccountOwner(account3), owner3, "Account3 owner mismatch");
    }

    function testGetImplementation() public {
        address implementation = _factory.getImplementation();
        assertEq(implementation, address(_hcaImplementation), "Implementation should match");
    }

    function testSetImplementationAsOwner() public {
        address newImpl = makeAddr("newImplementation");

        vm.prank(_factoryOwner);
        _factory.setImplementation(newImpl);

        assertEq(_factory.getImplementation(), newImpl, "Implementation should be updated");
    }

    function testSetImplementationFailsAsNonOwner() public {
        address newImpl = makeAddr("newImplementation");
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert();
        _factory.setImplementation(newImpl);
    }

    function testSetInitDataGeneratorChangesConfiguration() public {
        // Create a new generator with different bootstrap
        StaticK1Validator newValidator = new StaticK1Validator();
        bytes memory newInitData = abi.encodePacked(makeAddr("differentOwner"));
        NexusBootstrap newBootstrap = new NexusBootstrap(address(newValidator), newInitData);

        HCAInitDataGenerator newGenerator = new HCAInitDataGenerator(address(newBootstrap));

        vm.expectEmit(true, false, false, false);
        emit HCAFactory.InitDataGeneratorUpdated(address(newGenerator));

        vm.prank(_factoryOwner);
        _factory.setInitDataGenerator(newGenerator);

        // Test that new accounts use the new generator by creating one
        address newOwner = makeAddr("newOwnerForInitData");
        address account = _factory.createAccount(newOwner);

        // Account should still work (basic smoke test)
        assertTrue(
            account != address(0),
            "Account should be created successfully with new generator"
        );
    }

    function testGetAccountOwnerReturnsZeroForNonAccount() public {
        address randomAddr = makeAddr("randomAddress");
        address owner = _factory.getAccountOwner(randomAddr);
        assertEq(owner, address(0), "Non-account should return zero address");
    }

    function testAccountCreatedEvent() public {
        address newOwner = makeAddr("eventTestOwner");

        // Predict the account address before creation
        address predictedAccount = _factory.computeAccountAddress(newOwner);

        vm.expectEmit(true, true, false, false);
        emit HCAFactory.AccountCreated(newOwner, predictedAccount);

        _factory.createAccount(newOwner);
    }

    function testCreateAccountWithZeroAddress() public {
        // Should fail - StaticK1Validator rejects zero address as owner
        vm.expectRevert(); // Expect the deployment to fail due to OwnerCannotBeZeroAddress
        _factory.createAccount(address(0));
    }

    function testFallbackBlocksERC721AndERC1155Receivers() public {
        // onERC721Received
        (bool ok721, ) = address(_hca).call(abi.encodeWithSelector(0x150b7a02));
        assertFalse(ok721, "ERC721 receiver should revert");

        // onERC1155Received
        (bool ok1155, ) = address(_hca).call(abi.encodeWithSelector(0xf23a6e61));
        assertFalse(ok1155, "ERC1155 receiver should revert");

        // onERC1155BatchReceived
        (bool ok1155Batch, ) = address(_hca).call(abi.encodeWithSelector(0xbc197c81));
        assertFalse(ok1155Batch, "ERC1155 batch receiver should revert");
    }

    function testComputeAccountAddressConsistency() public {
        address owner = makeAddr("consistencyTestOwner");

        // Compute address multiple times
        address addr1 = _factory.computeAccountAddress(owner);
        address addr2 = _factory.computeAccountAddress(owner);
        address addr3 = _factory.computeAccountAddress(owner);

        // All should be identical
        assertEq(addr1, addr2, "Address computation should be consistent");
        assertEq(addr2, addr3, "Address computation should be consistent");

        // Should match actual creation
        address actualAddr = _factory.createAccount(owner);
        assertEq(addr1, actualAddr, "Computed address should match actual creation");
    }

    function testSetInitDataGeneratorAsOwner() public {
        HCAInitDataGenerator newGenerator = new HCAInitDataGenerator(address(_bootstrap));

        vm.expectEmit(true, false, false, false);
        emit HCAFactory.InitDataGeneratorUpdated(address(newGenerator));

        vm.prank(_factoryOwner);
        _factory.setInitDataGenerator(newGenerator);

        assertEq(
            address(_factory.getInitDataGenerator()),
            address(newGenerator),
            "Generator should be updated"
        );
    }

    function testSetInitDataGeneratorFailsAsNonOwner() public {
        HCAInitDataGenerator newGenerator = new HCAInitDataGenerator(address(_bootstrap));
        address nonOwner = makeAddr("nonOwner");

        vm.prank(nonOwner);
        vm.expectRevert();
        _factory.setInitDataGenerator(newGenerator);
    }

    function testGetInitDataGenerator() public {
        assertEq(
            address(_factory.getInitDataGenerator()),
            address(_initDataGenerator),
            "Should return correct generator"
        );
    }
}
