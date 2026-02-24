// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file, namechain/import-order-separation, gas-small-strings, gas-strict-inequalities, gas-increment-by-one, gas-custom-errors

import {Test} from "forge-std/Test.sol";

import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {
    L2ReverseRegistrarWithMigration,
    IL2ReverseRegistrarV1
} from "~src/reverse-registrar/L2ReverseRegistrarWithMigration.sol";
import {LibString} from "~src/utils/LibString.sol";

/// @title Mock Old L2 Reverse Registrar
/// @notice A mock implementation of the V1 reverse registrar interface for testing migration.
contract MockOldL2ReverseRegistrar is IL2ReverseRegistrarV1 {
    mapping(address addr => string name) private _names;

    function setMockName(address addr, string memory name) external {
        _names[addr] = name;
    }

    function nameForAddr(address addr) external view override returns (string memory) {
        return _names[addr];
    }
}

contract L2ReverseRegistrarWithMigrationTest is Test {
    // Constants matching Optimism chain setup
    uint256 constant OPTIMISM_CHAIN_ID = 10;
    string constant COIN_TYPE_LABEL = "8000000a";

    bytes32 constant REVERSE_NODE =
        0xa097f6721ce401e757d1223a763fef49b8b5f90bb18567ddb86fd205dff71d34;

    L2ReverseRegistrarWithMigration registrar;
    MockOldL2ReverseRegistrar mockOldRegistrar;

    // Test accounts
    address owner;
    address user1;
    address user2;
    address user3;
    address nonOwner;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = makeAddr("user1");
        user2 = makeAddr("user2");
        user3 = makeAddr("user3");
        nonOwner = makeAddr("nonOwner");

        // Deploy mock old registrar
        mockOldRegistrar = new MockOldL2ReverseRegistrar();

        // Deploy the L2ReverseRegistrarWithMigration
        registrar = new L2ReverseRegistrarWithMigration(
            OPTIMISM_CHAIN_ID,
            COIN_TYPE_LABEL,
            owner,
            IL2ReverseRegistrarV1(address(mockOldRegistrar))
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Helper Functions
    ////////////////////////////////////////////////////////////////////////

    function _getNode(address addr) internal view returns (bytes32) {
        string memory label = LibString.toAddressString(addr);
        return
            keccak256(
                abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
            );
    }

    ////////////////////////////////////////////////////////////////////////
    // Constructor Tests
    ////////////////////////////////////////////////////////////////////////

    function test_constructor_setsOwner() public view {
        assertEq(registrar.owner(), owner, "Owner should be set correctly");
    }

    function test_constructor_setsOldL2ReverseRegistrar() public view {
        assertEq(
            address(registrar.OLD_L2_REVERSE_REGISTRAR()),
            address(mockOldRegistrar),
            "OLD_L2_REVERSE_REGISTRAR should be set correctly"
        );
    }

    function test_constructor_setsChainId() public view {
        assertEq(registrar.CHAIN_ID(), OPTIMISM_CHAIN_ID, "CHAIN_ID should be set correctly");
    }

    function test_constructor_setsParentNode() public view {
        bytes32 expectedParentNode = keccak256(
            abi.encodePacked(REVERSE_NODE, keccak256(abi.encodePacked(COIN_TYPE_LABEL)))
        );
        assertEq(
            registrar.PARENT_NODE(),
            expectedParentNode,
            "PARENT_NODE should be set correctly"
        );
    }

    function test_constructor_differentOwner() public {
        address differentOwner = makeAddr("differentOwner");
        L2ReverseRegistrarWithMigration newRegistrar = new L2ReverseRegistrarWithMigration(
            OPTIMISM_CHAIN_ID,
            COIN_TYPE_LABEL,
            differentOwner,
            IL2ReverseRegistrarV1(address(mockOldRegistrar))
        );
        assertEq(newRegistrar.owner(), differentOwner, "Different owner should be set");
    }

    ////////////////////////////////////////////////////////////////////////
    // batchSetName Tests - Access Control
    ////////////////////////////////////////////////////////////////////////

    function test_batchSetName_revert_callerNotOwner() public {
        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, nonOwner)
        );
        vm.prank(nonOwner);
        registrar.batchSetName(addresses);
    }

    function test_batchSetName_onlyOwnerCanCall() public {
        mockOldRegistrar.setMockName(user1, "user1.eth");

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "user1.eth", "Name should be migrated");
    }

    ////////////////////////////////////////////////////////////////////////
    // batchSetName Tests - Single Address Migration
    ////////////////////////////////////////////////////////////////////////

    function test_batchSetName_migratesSingleAddress() public {
        string memory expectedName = "vitalik.eth";
        mockOldRegistrar.setMockName(user1, expectedName);

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), expectedName, "Name should be migrated correctly");
    }

    function test_batchSetName_emitsNameChangedEvent() public {
        string memory expectedName = "test.eth";
        mockOldRegistrar.setMockName(user1, expectedName);

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        bytes32 expectedNode = _getNode(user1);

        vm.expectEmit(true, false, false, true);
        emit INameResolver.NameChanged(expectedNode, expectedName);

        vm.prank(owner);
        registrar.batchSetName(addresses);
    }

    ////////////////////////////////////////////////////////////////////////
    // batchSetName Tests - Multiple Address Migration
    ////////////////////////////////////////////////////////////////////////

    function test_batchSetName_migratesMultipleAddresses() public {
        mockOldRegistrar.setMockName(user1, "user1.eth");
        mockOldRegistrar.setMockName(user2, "user2.eth");
        mockOldRegistrar.setMockName(user3, "user3.eth");

        address[] memory addresses = new address[](3);
        addresses[0] = user1;
        addresses[1] = user2;
        addresses[2] = user3;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        assertEq(registrar.name(_getNode(user1)), "user1.eth", "User1 name should be migrated");
        assertEq(registrar.name(_getNode(user2)), "user2.eth", "User2 name should be migrated");
        assertEq(registrar.name(_getNode(user3)), "user3.eth", "User3 name should be migrated");
    }

    function test_batchSetName_emitsMultipleNameChangedEvents() public {
        mockOldRegistrar.setMockName(user1, "user1.eth");
        mockOldRegistrar.setMockName(user2, "user2.eth");
        mockOldRegistrar.setMockName(user3, "user3.eth");

        address[] memory addresses = new address[](3);
        addresses[0] = user1;
        addresses[1] = user2;
        addresses[2] = user3;

        vm.expectEmit(true, false, false, true);
        emit INameResolver.NameChanged(_getNode(user1), "user1.eth");
        vm.expectEmit(true, false, false, true);
        emit INameResolver.NameChanged(_getNode(user2), "user2.eth");
        vm.expectEmit(true, false, false, true);
        emit INameResolver.NameChanged(_getNode(user3), "user3.eth");

        vm.prank(owner);
        registrar.batchSetName(addresses);
    }

    ////////////////////////////////////////////////////////////////////////
    // batchSetName Tests - Edge Cases
    ////////////////////////////////////////////////////////////////////////

    function test_batchSetName_emptyArray() public {
        address[] memory addresses = new address[](0);

        vm.prank(owner);
        registrar.batchSetName(addresses);

        // Should not revert, just do nothing
    }

    function test_batchSetName_addressWithNoNameInOldRegistrar() public {
        // user1 has no name set in old registrar (returns empty string by default)
        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "", "Name should be empty for address with no name");
    }

    function test_batchSetName_mixedAddressesWithAndWithoutNames() public {
        mockOldRegistrar.setMockName(user1, "user1.eth");
        // user2 has no name set
        mockOldRegistrar.setMockName(user3, "user3.eth");

        address[] memory addresses = new address[](3);
        addresses[0] = user1;
        addresses[1] = user2;
        addresses[2] = user3;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        assertEq(registrar.name(_getNode(user1)), "user1.eth", "User1 name should be migrated");
        assertEq(registrar.name(_getNode(user2)), "", "User2 should have empty name");
        assertEq(registrar.name(_getNode(user3)), "user3.eth", "User3 name should be migrated");
    }

    function test_batchSetName_duplicateAddressesInArray() public {
        mockOldRegistrar.setMockName(user1, "user1.eth");

        address[] memory addresses = new address[](3);
        addresses[0] = user1;
        addresses[1] = user1;
        addresses[2] = user1;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        // Should not revert, name should be set (same value written multiple times)
        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "user1.eth", "Name should be set correctly");
    }

    function test_batchSetName_overwritesExistingName() public {
        // First, set a name directly on the new registrar
        vm.prank(user1);
        registrar.setName("original.eth");

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "original.eth", "Original name should be set");

        // Now migrate from old registrar (overwrites)
        mockOldRegistrar.setMockName(user1, "migrated.eth");

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        assertEq(registrar.name(node), "migrated.eth", "Name should be overwritten by migration");
    }

    function test_batchSetName_handlesLongName() public {
        string memory longName = "very-long-ens-name-used-in-production.eth";
        mockOldRegistrar.setMockName(user1, longName);

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), longName, "Long name should be migrated correctly");
    }

    function test_batchSetName_handlesSpecialCharactersInName() public {
        string memory specialName = unicode"emoji🔥.eth";
        mockOldRegistrar.setMockName(user1, specialName);

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), specialName, "Special characters should be preserved");
    }

    ////////////////////////////////////////////////////////////////////////
    // batchSetName Tests - Large Batch
    ////////////////////////////////////////////////////////////////////////

    function test_batchSetName_largeBatch() public {
        uint256 batchSize = 100;
        address[] memory addresses = new address[](batchSize);

        for (uint256 i = 0; i < batchSize; i++) {
            address addr = address(uint160(i + 1));
            string memory name = string(abi.encodePacked("user", vm.toString(i), ".eth"));
            mockOldRegistrar.setMockName(addr, name);
            addresses[i] = addr;
        }

        vm.prank(owner);
        registrar.batchSetName(addresses);

        // Verify a few addresses
        assertEq(
            registrar.name(_getNode(address(1))),
            "user0.eth",
            "First address name should be migrated"
        );
        assertEq(
            registrar.name(_getNode(address(50))),
            "user49.eth",
            "Middle address name should be migrated"
        );
        assertEq(
            registrar.name(_getNode(address(100))),
            "user99.eth",
            "Last address name should be migrated"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // batchSetName Tests - Sequential Calls
    ////////////////////////////////////////////////////////////////////////

    function test_batchSetName_multipleBatchCalls() public {
        // First batch
        mockOldRegistrar.setMockName(user1, "user1.eth");
        address[] memory batch1 = new address[](1);
        batch1[0] = user1;

        vm.prank(owner);
        registrar.batchSetName(batch1);

        // Second batch
        mockOldRegistrar.setMockName(user2, "user2.eth");
        address[] memory batch2 = new address[](1);
        batch2[0] = user2;

        vm.prank(owner);
        registrar.batchSetName(batch2);

        assertEq(registrar.name(_getNode(user1)), "user1.eth", "User1 name should persist");
        assertEq(registrar.name(_getNode(user2)), "user2.eth", "User2 name should be migrated");
    }

    ////////////////////////////////////////////////////////////////////////
    // Inherited Functionality Tests
    ////////////////////////////////////////////////////////////////////////

    function test_inheritedSetName_stillWorks() public {
        vm.prank(user1);
        registrar.setName("direct.eth");

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "direct.eth", "Direct setName should work");
    }

    function test_inheritedSetNameForAddr_stillWorks() public {
        vm.prank(user1);
        registrar.setNameForAddr(user1, "foraddr.eth");

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "foraddr.eth", "setNameForAddr should work");
    }

    ////////////////////////////////////////////////////////////////////////
    // Ownership Tests
    ////////////////////////////////////////////////////////////////////////

    function test_transferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        registrar.transferOwnership(newOwner);

        assertEq(registrar.owner(), newOwner, "Ownership should be transferred");
    }

    function test_newOwnerCanCallBatchSetName() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        registrar.transferOwnership(newOwner);

        mockOldRegistrar.setMockName(user1, "user1.eth");
        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(newOwner);
        registrar.batchSetName(addresses);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "user1.eth", "New owner should be able to migrate");
    }

    function test_oldOwnerCannotCallBatchSetNameAfterTransfer() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        registrar.transferOwnership(newOwner);

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        registrar.batchSetName(addresses);
    }

    function test_renounceOwnership() public {
        vm.prank(owner);
        registrar.renounceOwnership();

        assertEq(registrar.owner(), address(0), "Owner should be zero address");

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, owner));
        registrar.batchSetName(addresses);
    }

    ////////////////////////////////////////////////////////////////////////
    // Fuzz Tests
    ////////////////////////////////////////////////////////////////////////

    function testFuzz_batchSetName_singleAddress(address addr, string memory name) public {
        vm.assume(addr != address(0)); // Avoid potential edge cases with zero address

        mockOldRegistrar.setMockName(addr, name);

        address[] memory addresses = new address[](1);
        addresses[0] = addr;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        bytes32 node = _getNode(addr);
        assertEq(registrar.name(node), name, "Fuzzed name should be migrated correctly");
    }

    function testFuzz_batchSetName_revertNonOwner(address caller) public {
        vm.assume(caller != owner);

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(caller);
        vm.expectRevert(
            abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, caller)
        );
        registrar.batchSetName(addresses);
    }

    ////////////////////////////////////////////////////////////////////////
    // Integration Tests
    ////////////////////////////////////////////////////////////////////////

    function test_integration_migrateAndResolve() public {
        string memory expectedName = "integration.eth";
        mockOldRegistrar.setMockName(user1, expectedName);

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        // Verify via direct name() call
        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), expectedName, "Direct name() should match");
    }

    function test_integration_migrateAndUpdateDirectly() public {
        // Step 1: Migrate from old registrar
        mockOldRegistrar.setMockName(user1, "migrated.eth");

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        vm.prank(owner);
        registrar.batchSetName(addresses);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "migrated.eth", "Migration should succeed");

        // Step 2: User updates their name directly
        vm.prank(user1);
        registrar.setName("updated.eth");

        assertEq(registrar.name(node), "updated.eth", "Direct update should succeed");
    }

    function test_integration_oldRegistrarValueChangesAfterMigration() public {
        // Set initial name in old registrar
        mockOldRegistrar.setMockName(user1, "initial.eth");

        address[] memory addresses = new address[](1);
        addresses[0] = user1;

        // Migrate
        vm.prank(owner);
        registrar.batchSetName(addresses);

        bytes32 node = _getNode(user1);
        assertEq(registrar.name(node), "initial.eth", "Initial migration should succeed");

        // Change name in old registrar (simulating someone using old registrar)
        mockOldRegistrar.setMockName(user1, "changed.eth");

        // New registrar should still have original migrated name
        assertEq(
            registrar.name(node),
            "initial.eth",
            "New registrar should not reflect old registrar changes"
        );

        // Re-migrate to get updated name
        vm.prank(owner);
        registrar.batchSetName(addresses);

        assertEq(registrar.name(node), "changed.eth", "Re-migration should update name");
    }
}
