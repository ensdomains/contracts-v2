// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file

import {Vm} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {UnauthorizedCaller} from "~src/CommonErrors.sol";
import {ReservedNameResolverUpdater} from "~src/registrar/ReservedNameResolverUpdater.sol";
import {IPermissionedRegistry} from "~src/registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "~src/registry/interfaces/IRegistry.sol";
import {IRegistryEvents} from "~src/registry/interfaces/IRegistryEvents.sol";
import {RegistryRolesLib} from "~src/registry/libraries/RegistryRolesLib.sol";
import {LibLabel} from "~src/utils/LibLabel.sol";
import {V2Fixture} from "~test/fixtures/V2Fixture.sol";

contract ReservedNameResolverUpdaterTest is V2Fixture {
    ReservedNameResolverUpdater updater;

    address owner = address(this);
    address oldResolver = address(0xA11CE);
    address newResolver = address(0xB0B);
    address subregistry = address(0x5B);
    uint64 expiry;

    function setUp() external {
        deployV2Fixture();
        updater = new ReservedNameResolverUpdater(rootRegistry, newResolver, owner);
        rootRegistry.grantRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(updater)
        );
        expiry = uint64(block.timestamp + 365 days);
    }

    function _reserve(string memory label, address registry, address resolver) internal {
        rootRegistry.register(label, address(0), IRegistry(registry), resolver, 0, expiry);
    }

    function _labels(string memory a) internal pure returns (string[] memory labels) {
        labels = new string[](1);
        labels[0] = a;
    }

    function _labels(string memory a, string memory b)
        internal
        pure
        returns (string[] memory labels)
    {
        labels = new string[](2);
        labels[0] = a;
        labels[1] = b;
    }

    function test_updateResolvers_moves_reserved_names() external {
        _reserve("com", address(0), oldResolver);
        _reserve("org", subregistry, oldResolver);

        updater.updateResolvers(_labels("com", "org"));

        string[2] memory labels = ["com", "org"];
        for (uint256 i; i < labels.length; ++i) {
            IPermissionedRegistry.State memory state = rootRegistry.getState(LibLabel.id(labels[i]));
            assertEq(
                uint256(state.status),
                uint256(IPermissionedRegistry.Status.RESERVED),
                "reserved"
            );
            assertEq(state.expiry, expiry, "expiry kept");
            assertEq(state.latestOwner, address(0), "no owner");
            assertEq(rootRegistry.getResolver(labels[i]), newResolver, "resolver");
            assertEq(rootRegistry.roles(state.resource, address(updater)), 0, "no role on the name");
        }
        assertEq(address(rootRegistry.getSubregistry("com")), address(0), "subregistry kept");
        assertEq(address(rootRegistry.getSubregistry("org")), subregistry, "subregistry kept");
        assertTrue(
            rootRegistry.hasRootRoles(
                RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_REGISTER_RESERVED,
                address(updater)
            ),
            "root roles untouched"
        );
    }

    function test_updateResolvers_registers_unregisters_and_reserves_in_one_call() external {
        _reserve("com", address(0), oldResolver);
        uint256 labelId = LibLabel.id("com");

        vm.recordLogs();
        updater.updateResolvers(_labels("com"));
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32[3] memory expected =
            [IRegistryEvents.LabelRegistered.selector, IRegistryEvents.LabelUnregistered.selector, IRegistryEvents.LabelReserved.selector];
        uint256 next;
        for (uint256 i; i < logs.length && next < expected.length; ++i) {
            if (logs[i].emitter != address(rootRegistry) || logs[i].topics[0] != expected[next]) {
                continue;
            }
            if (next == 0) {
                (, address registeredOwner, ) = abi.decode(logs[i].data, (string, address, uint64));
                assertEq(logs[i].topics[2], bytes32(labelId), "registered label");
                assertEq(registeredOwner, address(updater), "registered to the updater");
            } else if (next == 1) {
                assertEq(
                    address(uint160(uint256(logs[i].topics[2]))),
                    address(updater),
                    "unregistered by the updater"
                );
            } else {
                assertEq(logs[i].topics[2], bytes32(labelId), "reserved label");
                (string memory label, uint64 reservedExpiry) =
                    abi.decode(logs[i].data, (string, uint64));
                assertEq(label, "com", "reserved label text");
                assertEq(reservedExpiry, expiry, "reserved with the original expiry");
            }
            ++next;
        }
        assertEq(next, expected.length, "register, unregister and reserve, in order");
    }

    function test_updateResolvers_skips_names_already_moved() external {
        _reserve("com", address(0), newResolver);

        vm.recordLogs();
        updater.updateResolvers(_labels("com"));
        assertEq(vm.getRecordedLogs().length, 0, "nothing changed");
        assertEq(rootRegistry.getResolver("com"), newResolver, "resolver");
    }

    function test_updateResolvers_rejects_an_available_name_and_changes_nothing() external {
        _reserve("com", address(0), oldResolver);

        vm.expectRevert(
            abi.encodeWithSelector(ReservedNameResolverUpdater.NameNotReserved.selector, "net")
        );
        updater.updateResolvers(_labels("com", "net"));

        assertEq(rootRegistry.getResolver("com"), oldResolver, "first name untouched");
    }

    function test_updateResolvers_rejects_a_registered_name() external {
        rootRegistry.register("com", address(this), IRegistry(address(0)), oldResolver, 0, expiry);

        vm.expectRevert(
            abi.encodeWithSelector(ReservedNameResolverUpdater.NameNotReserved.selector, "com")
        );
        updater.updateResolvers(_labels("com"));
    }

    function test_updateResolvers_only_owner() external {
        _reserve("com", address(0), oldResolver);
        address other = address(0xBAD);

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, other));
        vm.prank(other);
        updater.updateResolvers(_labels("com"));
    }

    function test_updateResolvers_needs_the_root_roles() external {
        _reserve("com", address(0), oldResolver);
        rootRegistry.revokeRootRoles(
            RegistryRolesLib.ROLE_REGISTRAR | RegistryRolesLib.ROLE_REGISTER_RESERVED,
            address(updater)
        );

        vm.expectRevert();
        updater.updateResolvers(_labels("com"));
        assertEq(rootRegistry.getResolver("com"), oldResolver, "untouched");
    }

    function test_onERC1155Received_only_from_the_registry() external {
        address other = address(0xBAD);
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, other));
        vm.prank(other);
        updater.onERC1155Received(address(0), address(0), 0, 1, "");
    }

    function test_onERC1155BatchReceived_always_reverts() external {
        vm.expectRevert(abi.encodeWithSelector(UnauthorizedCaller.selector, address(rootRegistry)));
        vm.prank(address(rootRegistry));
        updater.onERC1155BatchReceived(
            address(0),
            address(0),
            new uint256[](0),
            new uint256[](0),
            ""
        );
    }

    function test_supportsInterface() external view {
        assertTrue(updater.supportsInterface(type(IERC1155Receiver).interfaceId), "IERC1155Receiver");
        assertTrue(updater.supportsInterface(type(IERC165).interfaceId), "IERC165");
        assertFalse(updater.supportsInterface(0xffffffff), "unknown");
    }
}
