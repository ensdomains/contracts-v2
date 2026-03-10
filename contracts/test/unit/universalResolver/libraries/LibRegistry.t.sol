// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, contracts-v2/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";

import {EACBaseRolesLib} from "~src/access-control/EnhancedAccessControl.sol";
import {IHCAFactoryBasic} from "~src/hca/interfaces/IHCAFactoryBasic.sol";
import {
    PermissionedRegistry,
    IStandardRegistry,
    IRegistry,
    IRegistryMetadata
} from "~src/registry/PermissionedRegistry.sol";
import {LibRegistry, NameCoder} from "~src/universalResolver/libraries/LibRegistry.sol";

contract LibRegistryTest is Test, ERC1155Holder {
    PermissionedRegistry rootRegistry;
    address resolverAddress = makeAddr("resolver");

    function _createRegistry() internal returns (PermissionedRegistry) {
        return
            new PermissionedRegistry(
                IHCAFactoryBasic(address(0)),
                IRegistryMetadata(address(0)),
                address(this),
                EACBaseRolesLib.ALL_ROLES
            );
    }
    function _register(
        PermissionedRegistry parentRegistry,
        string memory label,
        IRegistry registry,
        address resolver
    ) internal {
        parentRegistry.register(
            label,
            address(this),
            registry,
            resolver,
            EACBaseRolesLib.ALL_ROLES,
            uint64(block.timestamp + 1000)
        );
        if (
            ERC165Checker.supportsInterface(address(registry), type(IStandardRegistry).interfaceId)
        ) {
            IStandardRegistry(address(registry)).setParent(parentRegistry, label);
        }
    }

    function setUp() external {
        rootRegistry = _createRegistry();
    }

    function _expectFind(
        bytes memory name,
        uint256 resolverOffset,
        address parentRegistry,
        IRegistry[] memory registries,
        bytes memory canonicalName
    ) internal view {
        (IRegistry registry, address resolver, bytes32 node, uint256 resolverOffset_) = LibRegistry
            .findResolver(rootRegistry, name, 0);
        assertEq(
            address(LibRegistry.findExactRegistry(rootRegistry, name, 0)),
            address(registry),
            "exact"
        );
        assertEq(resolver, resolverAddress, "resolver");
        assertEq(node, NameCoder.namehash(name, 0), "node");
        assertEq(resolverOffset_, resolverOffset, "offset");
        assertEq(
            address(LibRegistry.findParentRegistry(rootRegistry, name, 0)),
            parentRegistry,
            "parent"
        );
        {
            IRegistry[] memory regs = LibRegistry.findRegistries(rootRegistry, name, 0);
            assertEq(registries.length, regs.length, "count");
            for (uint256 i; i < regs.length; ++i) {
                assertEq(
                    address(registries[i]),
                    address(regs[i]),
                    string.concat("registry[", vm.toString(i), "]")
                );
            }
        }
        uint256 offset;
        for (uint256 i; i < registries.length; ++i) {
            assertEq(
                address(LibRegistry.findExactRegistry(rootRegistry, name, offset)),
                address(registries[i]),
                string.concat("exact[", vm.toString(i), "]")
            );
            (, offset) = NameCoder.nextLabel(name, offset);
        }
        assertEq(offset, name.length, "length");
        (IRegistry registryFrom, address resolverFrom) = LibRegistry.findResolverFromParent(
            name,
            0,
            name.length - 1,
            rootRegistry,
            address(0)
        );
        assertEq(address(registryFrom), address(registry), "registryFrom");
        assertEq(resolverFrom, resolver, "resolverFrom");
        assertEq(
            LibRegistry.findCanonicalName(rootRegistry, registries[0]),
            canonicalName,
            "findCanonicalName"
        );
        if (canonicalName.length > 0) {
            assertEq(
                address(LibRegistry.findCanonicalRegistry(rootRegistry, canonicalName)),
                address(registries[0]),
                "findCanonicalRegistry"
            );
        }
    }

    function test_findResolver_eth() external {
        bytes memory name = NameCoder.encode("eth");
        //     name:  eth
        // registry: <eth> <root>
        // resolver:   X
        vm.pauseGasMetering();
        PermissionedRegistry ethRegistry = _createRegistry();
        _register(rootRegistry, "eth", ethRegistry, resolverAddress);
        vm.resumeGasMetering();

        IRegistry[] memory v = new IRegistry[](2);
        v[0] = ethRegistry;
        v[1] = rootRegistry;
        _expectFind(name, 0, address(rootRegistry), v, name);
    }

    function test_findResolver_resolverOnParent() external {
        bytes memory name = NameCoder.encode("test.eth");
        //     name:  test . eth
        // registry: <test> <eth> <root>
        // resolver:   X
        vm.pauseGasMetering();
        PermissionedRegistry ethRegistry = _createRegistry();
        PermissionedRegistry testRegistry = _createRegistry();
        _register(rootRegistry, "eth", ethRegistry, address(0));
        _register(ethRegistry, "test", testRegistry, resolverAddress);
        vm.resumeGasMetering();

        IRegistry[] memory v = new IRegistry[](3);
        v[0] = testRegistry;
        v[1] = ethRegistry;
        v[2] = rootRegistry;
        _expectFind(name, 0, address(ethRegistry), v, name);
    }

    function test_findResolver_resolverOnRoot() external {
        bytes memory name = NameCoder.encode("sub.test.eth");
        //     name:  sub . test . eth
        // registry:       <test> <eth> <root>
        // resolver:                X
        vm.pauseGasMetering();
        PermissionedRegistry ethRegistry = _createRegistry();
        PermissionedRegistry testRegistry = _createRegistry();
        _register(rootRegistry, "eth", ethRegistry, resolverAddress);
        _register(ethRegistry, "test", testRegistry, address(0));
        vm.resumeGasMetering();

        IRegistry[] memory v = new IRegistry[](4);
        v[1] = testRegistry;
        v[2] = ethRegistry;
        v[3] = rootRegistry;
        _expectFind(name, 9, address(testRegistry), v, ""); // 3sub4test
    }

    function test_findResolver_virtual() external {
        bytes memory name = NameCoder.encode("a.bb.test.eth");
        //     name:  a . bb . test . eth
        // registry:          <test> <eth> <root>
        // resolver:                   X
        vm.pauseGasMetering();
        PermissionedRegistry ethRegistry = _createRegistry();
        PermissionedRegistry testRegistry = _createRegistry();
        _register(rootRegistry, "eth", ethRegistry, resolverAddress);
        _register(ethRegistry, "test", testRegistry, address(0));
        vm.resumeGasMetering();

        IRegistry[] memory v = new IRegistry[](5);
        v[2] = testRegistry;
        v[3] = ethRegistry;
        v[4] = rootRegistry;
        _expectFind(name, 10, address(0), v, ""); // 1a2bb4test
    }

    function test_findCanonicalName() external {
        PermissionedRegistry ethRegistry = _createRegistry();
        PermissionedRegistry testRegistry = _createRegistry();
        PermissionedRegistry subRegistry = _createRegistry();
        _register(rootRegistry, "eth", ethRegistry, address(0));
        _register(ethRegistry, "test", testRegistry, address(0));
        _register(testRegistry, "sub", subRegistry, address(0));
        assertEq(
            LibRegistry.findCanonicalName(rootRegistry, rootRegistry),
            NameCoder.encode(""),
            "<root>"
        );
        assertEq(
            LibRegistry.findCanonicalName(rootRegistry, ethRegistry),
            NameCoder.encode("eth"),
            "eth"
        );
        assertEq(
            LibRegistry.findCanonicalName(rootRegistry, testRegistry),
            NameCoder.encode("test.eth"),
            "test"
        );
        assertEq(
            LibRegistry.findCanonicalName(rootRegistry, subRegistry),
            NameCoder.encode("sub.test.eth"),
            "sub"
        );
    }

    function test_findCanonicalRegistry() external {
        PermissionedRegistry ethRegistry = _createRegistry();
        PermissionedRegistry testRegistry = _createRegistry();
        PermissionedRegistry subRegistry = _createRegistry();
        _register(rootRegistry, "eth", ethRegistry, address(0));
        _register(ethRegistry, "test", testRegistry, address(0));
        _register(testRegistry, "sub", subRegistry, address(0));
        assertEq(
            address(LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode(""))),
            address(rootRegistry),
            "<root>"
        );
        assertEq(
            address(LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode("eth"))),
            address(ethRegistry),
            "eth"
        );
        assertEq(
            address(LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode("test.eth"))),
            address(testRegistry),
            "test"
        );
        assertEq(
            address(
                LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode("sub.test.eth"))
            ),
            address(subRegistry),
            "sub"
        );
    }

    function test_findCanonicalRegistry_emptyName() external {
        vm.expectRevert(abi.encodeWithSelector(NameCoder.DNSDecodingFailed.selector, ""));
        this._findCanonicalRegistry("");
    }

    function test_findCanonicalRegistry_invalidName() external {
        bytes memory name = new bytes(2);
        vm.expectRevert(abi.encodeWithSelector(NameCoder.DNSDecodingFailed.selector, name));
        this._findCanonicalRegistry(name);
    }

    function _findCanonicalRegistry(bytes calldata name) external view {
        LibRegistry.findCanonicalRegistry(rootRegistry, name);
    }

    function test_findCanonical_wrongRegistry() external {
        PermissionedRegistry ethRegistry = _createRegistry();
        PermissionedRegistry testRegistry = _createRegistry();
        _register(rootRegistry, "eth", ethRegistry, address(0));
        _register(ethRegistry, "test", testRegistry, address(0));
        ethRegistry.setParent(IRegistry(address(0)), "eth"); // wrong
        assertEq(
            LibRegistry.findCanonicalName(rootRegistry, testRegistry),
            "",
            "findCanonicalName"
        );
        assertEq(
            address(LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode("test.eth"))),
            address(0),
            "findCanonicalRegistry"
        );
    }

    function test_findCanonical_wrongLabel() external {
        PermissionedRegistry ethRegistry = _createRegistry();
        PermissionedRegistry testRegistry = _createRegistry();
        _register(rootRegistry, "eth", ethRegistry, address(0));
        _register(ethRegistry, "test", testRegistry, address(0));
        ethRegistry.setParent(IRegistry(address(0)), "xyz"); // wrong
        assertEq(
            LibRegistry.findCanonicalName(rootRegistry, testRegistry),
            "",
            "findCanonicalName"
        );
        assertEq(
            address(LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode("test.eth"))),
            address(0),
            "findCanonicalRegistry"
        );
    }

    function test_findCanonical_aliased() external {
        PermissionedRegistry ethRegistry = _createRegistry();
        PermissionedRegistry testRegistry = _createRegistry();
        _register(rootRegistry, "eth", ethRegistry, address(0));
        _register(ethRegistry, "test", testRegistry, address(0));
        assertEq(
            LibRegistry.findCanonicalName(rootRegistry, testRegistry),
            NameCoder.encode("test.eth"),
            "eth"
        );
        assertEq(
            address(LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode("test.eth"))),
            address(testRegistry),
            "eth:test.eth"
        );
        assertEq(
            address(LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode("test.xyz"))),
            address(0),
            "eth:test.xyz"
        );
        _register(rootRegistry, "xyz", ethRegistry, address(0));
        assertEq(
            LibRegistry.findCanonicalName(rootRegistry, testRegistry),
            NameCoder.encode("test.xyz"),
            "xyz"
        );
        assertEq(
            address(LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode("test.xyz"))),
            address(testRegistry),
            "xyz:test.xyz"
        );
        assertEq(
            address(LibRegistry.findCanonicalRegistry(rootRegistry, NameCoder.encode("test.eth"))),
            address(0),
            "xyz:test.eth"
        );
    }
}
