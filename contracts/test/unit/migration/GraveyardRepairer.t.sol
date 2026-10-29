// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {console} from "forge-std/console.sol";
import {Vm} from "forge-std/Vm.sol";

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {GraveyardRepairer} from "~src/migration/GraveyardRepairer.sol";
import {MigrationControllerFixture} from "~test/fixtures/MigrationControllerFixture.sol";

contract GraveyardRepairerTest is MigrationControllerFixture {
    /// @dev Batch size for the gas measurement. Large enough that the fixed
    ///      per-transaction overhead amortises to noise.
    uint256 constant GAS_BATCH = 50;

    /// @dev Band the measured per-name repair cost must sit inside. Wide enough
    ///      to hold for an optimised build and for a coverage build.
    uint256 constant GAS_PER_REPAIR_MIN = 30_000;
    uint256 constant GAS_PER_REPAIR_MAX = 150_000;

    uint64 constant POISONED_TTL = 3600;

    GraveyardRepairer repairer;
    address evilResolver = makeAddr("evilResolver");

    function setUp() external {
        deployMigrationControllerFixture();
        repairer = new GraveyardRepairer(graveyard);
        baseRegistrar.addController(address(repairer));
    }

    function test_constructor() external view {
        assertEq(repairer.GRAVEYARD(), address(graveyard));
    }

    function test_repair_poisoned() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped(testLabel);
        bytes32 node = NameCoder.namehash(name, 0);
        _poison(name);

        _simulateExpiry(name);
        assertTrue(repairer.isRepairable(tokenId), "repairable");

        vm.recordLogs();
        assertEq(repairer.repair(_oneId(tokenId)), 1, "repaired");
        _assertRepairedEvent(vm.getRecordedLogs(), tokenId);

        assertEq(registryV1.owner(node), address(graveyard), "owner");
        assertEq(registryV1.resolver(node), address(0), "resolver");
        assertEq(registryV1.ttl(node), POISONED_TTL, "ttl");
        assertEq(baseRegistrar.ownerOf(tokenId), address(graveyard), "token");
        assertEq(baseRegistrar.nameExpires(tokenId), type(uint64).max - gracePeriodV1 + 1, "expiry");
        assertEq(findResolverV1(name), address(ensV2Resolver), "resolution");
        assertFalse(repairer.isRepairable(tokenId), "repaired once");
    }

    function test_repair_matchesGraveyardClear() external {
        (bytes memory poisoned, uint256 poisonedId) = registerUnwrapped(_label(0));
        (bytes memory expired, uint256 expiredId) = registerUnwrapped(_label(1));
        _poison(poisoned);
        vm.prank(testOwner);
        registryV1.setResolver(NameCoder.namehash(expired, 0), evilResolver);

        _simulateExpiry(poisoned);
        repairer.repair(_oneId(poisonedId));
        graveyard.clear(_oneName(expired));

        bytes32 a = NameCoder.namehash(poisoned, 0);
        bytes32 b = NameCoder.namehash(expired, 0);
        assertEq(registryV1.owner(a), registryV1.owner(b), "owner");
        assertEq(registryV1.resolver(a), registryV1.resolver(b), "resolver");
        assertEq(baseRegistrar.ownerOf(poisonedId), baseRegistrar.ownerOf(expiredId), "token");
        assertEq(
            baseRegistrar.nameExpires(poisonedId),
            baseRegistrar.nameExpires(expiredId),
            "expiry"
        );
    }

    function test_repair_live_skipped() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped(testLabel);
        bytes32 node = NameCoder.namehash(name, 0);
        _poison(name);

        assertFalse(repairer.isRepairable(tokenId), "live");
        assertEq(repairer.repair(_oneId(tokenId)), 0, "live");
        assertEq(baseRegistrar.ownerOf(tokenId), testOwner, "token");

        vm.warp(baseRegistrar.nameExpires(tokenId) + 1);
        assertFalse(repairer.isRepairable(tokenId), "grace");
        assertEq(repairer.repair(_oneId(tokenId)), 0, "grace");

        assertEq(registryV1.resolver(node), evilResolver, "untouched");
    }

    function test_repair_migrated_noWrites() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped(testLabel);
        _simulateMigration(name);
        _simulateExpiry(name);

        vm.recordLogs();
        assertEq(repairer.repair(_oneId(tokenId)), 0, "repaired");
        assertEq(vm.getRecordedLogs().length, 0, "logs");
    }

    function test_repair_handedToRepairer_skipped() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped(testLabel);
        bytes32 node = NameCoder.namehash(name, 0);
        vm.prank(testOwner);
        registryV1.setRecord(node, address(repairer), evilResolver, 0);

        _simulateExpiry(name);
        assertFalse(repairer.isRepairable(tokenId), "repairable");
        assertEq(repairer.repair(_oneId(tokenId)), 0, "repaired");

        // the graveyard takes over a node it does not own
        graveyard.clear(_oneName(name));
        assertEq(registryV1.owner(node), address(graveyard), "owner");
        assertEq(registryV1.resolver(node), address(0), "resolver");
    }

    function test_repair_neverRegistered_skipped() external {
        bytes32 labelHash = keccak256(bytes(testLabel));
        bytes32 node = NameCoder.namehash(NameCoder.ETH_NODE, labelHash);
        vm.prank(address(baseRegistrar));
        registryV1.setSubnodeRecord(
            NameCoder.ETH_NODE,
            labelHash,
            address(graveyard),
            evilResolver,
            0
        );

        assertFalse(repairer.isRepairable(uint256(labelHash)), "repairable");
        assertEq(repairer.repair(_oneId(uint256(labelHash))), 0, "repaired");
        assertEq(registryV1.resolver(node), evilResolver, "untouched");
    }

    function test_repair_mixed() external {
        (bytes memory poisoned, uint256 poisonedId) = registerUnwrapped(_label(0));
        (bytes memory migrated, uint256 migratedId) = registerUnwrapped(_label(1));
        (, uint256 expiredId) = registerUnwrapped(_label(2));
        _poison(poisoned);
        _simulateMigration(migrated);
        _simulateExpiry(poisoned);
        (bytes memory live, uint256 liveId) = registerUnwrapped(_label(3));
        _poison(live);

        uint256[] memory ids = new uint256[](6);
        ids[0] = poisonedId;
        ids[1] = migratedId;
        ids[2] = poisonedId; // duplicate
        ids[3] = expiredId;
        ids[4] = liveId;
        ids[5] = uint256(keccak256("unregistered"));

        vm.recordLogs();
        assertEq(repairer.repair(ids), 1, "repaired");
        _assertRepairedEvent(vm.getRecordedLogs(), poisonedId);
        assertEq(registryV1.resolver(NameCoder.namehash(poisoned, 0)), address(0), "poisoned");
        assertEq(registryV1.resolver(NameCoder.namehash(live, 0)), evilResolver, "live");
    }

    function test_repair_thenClearSubnames() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped(testLabel);
        bytes memory child = NameCoder.addLabel(name, testLabel);
        bytes32 childNode = NameCoder.namehash(child, 0);
        vm.prank(testOwner);
        registryV1.setSubnodeRecord(
            NameCoder.namehash(name, 0),
            keccak256(bytes(testLabel)),
            testOwner,
            evilResolver,
            0
        );
        _poison(name);
        _simulateExpiry(name);

        repairer.repair(_oneId(tokenId));
        graveyard.clear(_oneName(child));

        assertEq(registryV1.resolver(NameCoder.namehash(name, 0)), address(0), "name");
        assertEq(registryV1.owner(childNode), address(graveyard), "child owner");
        assertEq(registryV1.resolver(childNode), address(0), "child resolver");
    }

    function test_repair_notController() external {
        (bytes memory name, uint256 tokenId) = registerUnwrapped(testLabel);
        _poison(name);
        _simulateExpiry(name);
        baseRegistrar.removeController(address(repairer));

        vm.expectRevert();
        repairer.repair(_oneId(tokenId));
    }

    function test_gas_repair_poisoned2LDs() external {
        uint256[] memory ids = new uint256[](GAS_BATCH);
        bytes memory name;
        for (uint256 i; i < GAS_BATCH; ++i) {
            (name, ids[i]) = registerUnwrapped(_label(i));
            _poison(name);
        }
        _simulateExpiry(name);

        uint256 before = gasleft();
        assertEq(repairer.repair(ids), GAS_BATCH, "repaired");
        uint256 perName = (before - gasleft()) / GAS_BATCH;
        console.log("repair() gas per poisoned 2LD:", perName);
        assertGt(perName, GAS_PER_REPAIR_MIN, "below band");
        assertLt(perName, GAS_PER_REPAIR_MAX, "above band");
    }

    ////////////////////////////////////////////////////////////////////////
    // Helpers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Hand the registry node to the graveyard with a resolver set, keeping the token.
    function _poison(bytes memory name) internal {
        bytes32 node = NameCoder.namehash(name, 0);
        vm.prank(registryV1.owner(node));
        registryV1.setRecord(node, address(graveyard), evilResolver, POISONED_TTL);
    }

    function _assertRepairedEvent(Vm.Log[] memory logs, uint256 tokenId) internal view {
        uint256 found;
        for (uint256 i; i < logs.length; ++i) {
            if (
                logs[i].emitter == address(repairer) &&
                logs[i].topics[0] == GraveyardRepairer.Repaired.selector
            ) {
                assertEq(logs[i].topics[1], bytes32(tokenId), "tokenId");
                ++found;
            }
        }
        assertEq(found, 1, "Repaired");
    }

    function _oneId(uint256 tokenId) internal pure returns (uint256[] memory ids) {
        ids = new uint256[](1);
        ids[0] = tokenId;
    }

    function _oneName(bytes memory name) internal pure returns (bytes[] memory names) {
        names = new bytes[](1);
        names[0] = name;
    }
}
