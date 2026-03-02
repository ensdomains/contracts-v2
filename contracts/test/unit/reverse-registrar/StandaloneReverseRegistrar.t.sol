// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file, namechain/import-order-separation, gas-small-strings, gas-strict-inequalities, gas-increment-by-one, gas-custom-errors

import {Test, Vm} from "forge-std/Test.sol";

import {IExtendedResolver} from "@ens/contracts/resolvers/profiles/IExtendedResolver.sol";
import {INameResolver} from "@ens/contracts/resolvers/profiles/INameResolver.sol";
import {ERC165Checker} from "@openzeppelin/contracts/utils/introspection/ERC165Checker.sol";
import {IERC165} from "@openzeppelin/contracts/utils/introspection/IERC165.sol";

import {IENSIP16} from "~src/utils/interfaces/IENSIP16.sol";
import {LibString} from "~src/utils/LibString.sol";
import {StandaloneReverseRegistrar} from "~src/reverse-registrar/StandaloneReverseRegistrar.sol";

import {
    MockStandaloneReverseRegistrarImplementer
} from "~test/mocks/MockStandaloneReverseRegistrarImplementer.sol";

contract StandaloneReverseRegistrarTest is Test {
    // Constants matching the contract
    bytes32 constant REVERSE_NODE =
        0xa097f6721ce401e757d1223a763fef49b8b5f90bb18567ddb86fd205dff71d34;

    // Test parameters
    uint256 constant ETH_COIN_TYPE = 60;
    string constant ETH_LABEL = "default";

    MockStandaloneReverseRegistrarImplementer registrar;

    address user1 = makeAddr("user1");
    address user2 = makeAddr("user2");

    function setUp() public {
        registrar = new MockStandaloneReverseRegistrarImplementer(ETH_LABEL);
    }

    ////////////////////////////////////////////////////////////////////////
    // Constructor / Immutables Tests
    ////////////////////////////////////////////////////////////////////////

    function test_constructor_setParentNode() public view {
        bytes32 expectedParentNode = keccak256(
            abi.encodePacked(REVERSE_NODE, keccak256(abi.encodePacked(ETH_LABEL)))
        );
        assertEq(registrar.PARENT_NODE(), expectedParentNode, "PARENT_NODE should match");
    }

    function test_constructor_setSimpleHashedParent() public view {
        bytes memory parent = abi.encodePacked(
            uint8(bytes(ETH_LABEL).length),
            ETH_LABEL,
            uint8(7),
            "reverse",
            uint8(0)
        );
        bytes32 expectedHash = keccak256(parent);
        assertEq(
            registrar.SIMPLE_HASHED_PARENT(),
            expectedHash,
            "SIMPLE_HASHED_PARENT should match"
        );
    }

    function test_constructor_setParentLength() public view {
        bytes memory parent = abi.encodePacked(
            uint8(bytes(ETH_LABEL).length),
            ETH_LABEL,
            uint8(7),
            "reverse",
            uint8(0)
        );
        assertEq(registrar.PARENT_LENGTH(), parent.length, "PARENT_LENGTH should match");
    }

    function testFuzz_constructor_differentLabels(string memory label) public {
        vm.assume(bytes(label).length > 0 && bytes(label).length <= 255);

        MockStandaloneReverseRegistrarImplementer newRegistrar = new MockStandaloneReverseRegistrarImplementer(
                label
            );

        bytes32 expectedParentNode = keccak256(
            abi.encodePacked(REVERSE_NODE, keccak256(abi.encodePacked(label)))
        );
        assertEq(newRegistrar.PARENT_NODE(), expectedParentNode, "PARENT_NODE should match");

        bytes memory parent = abi.encodePacked(
            uint8(bytes(label).length),
            label,
            uint8(7),
            "reverse",
            uint8(0)
        );
        assertEq(newRegistrar.SIMPLE_HASHED_PARENT(), keccak256(parent), "SIMPLE_HASHED_PARENT");
        assertEq(newRegistrar.PARENT_LENGTH(), parent.length, "PARENT_LENGTH should match");
    }

    ////////////////////////////////////////////////////////////////////////
    // supportsInterface Tests
    ////////////////////////////////////////////////////////////////////////

    function test_supportsInterface_erc165() public view {
        assertTrue(ERC165Checker.supportsERC165(address(registrar)), "Should support ERC165");
    }

    function test_supportsInterface_extendedResolver() public view {
        assertTrue(
            registrar.supportsInterface(type(IExtendedResolver).interfaceId),
            "Should support IExtendedResolver"
        );
    }

    function test_supportsInterface_nameResolver() public view {
        assertTrue(
            registrar.supportsInterface(type(INameResolver).interfaceId),
            "Should support INameResolver"
        );
    }

    function test_supportsInterface_ierc165() public view {
        assertTrue(
            registrar.supportsInterface(type(IERC165).interfaceId),
            "Should support IERC165"
        );
    }

    function test_supportsInterface_invalidInterface() public view {
        assertFalse(
            registrar.supportsInterface(bytes4(0xdeadbeef)),
            "Should not support random interface"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // name() Tests
    ////////////////////////////////////////////////////////////////////////

    function test_name_returnsEmptyForUnsetNode() public view {
        bytes32 randomNode = keccak256("random");
        assertEq(registrar.name(randomNode), "", "Should return empty for unset node");
    }

    function test_name_returnsSetName() public {
        string memory expectedName = "vitalik.eth";
        registrar.setName(user1, expectedName);

        string memory label = LibString.toAddressString(user1);
        bytes32 node = keccak256(
            abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
        );

        assertEq(registrar.name(node), expectedName, "Should return set name");
    }

    function testFuzz_name_returnsSetName(address addr, string memory expectedName) public {
        registrar.setName(addr, expectedName);

        string memory label = LibString.toAddressString(addr);
        bytes32 node = keccak256(
            abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
        );

        assertEq(registrar.name(node), expectedName, "Should return set name");
    }

    ////////////////////////////////////////////////////////////////////////
    // resolve() Tests
    ////////////////////////////////////////////////////////////////////////

    function test_resolve_returnsEncodedName() public {
        string memory expectedName = "nick.eth";
        registrar.setName(user1, expectedName);

        // Build DNS-encoded name for user1
        bytes memory dnsEncodedName = _buildDnsEncodedName(user1);

        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));
        bytes memory result = registrar.resolve(dnsEncodedName, data);

        string memory decodedName = abi.decode(result, (string));
        assertEq(decodedName, expectedName, "Should return encoded name");
    }

    function test_resolve_returnsEmptyForUnsetAddress() public {
        bytes memory dnsEncodedName = _buildDnsEncodedName(user1);
        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));
        bytes memory result = registrar.resolve(dnsEncodedName, data);

        string memory decodedName = abi.decode(result, (string));
        assertEq(decodedName, "", "Should return empty for unset address");
    }

    function testFuzz_resolve_differentAddresses(address addr, string memory expectedName) public {
        registrar.setName(addr, expectedName);

        bytes memory dnsEncodedName = _buildDnsEncodedName(addr);
        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));
        bytes memory result = registrar.resolve(dnsEncodedName, data);

        string memory decodedName = abi.decode(result, (string));
        assertEq(decodedName, expectedName, "Should return correct name");
    }

    function test_resolve_revert_unsupportedResolverProfile() public {
        bytes memory dnsEncodedName = _buildDnsEncodedName(user1);
        // Use a different selector (e.g., addr(bytes32))
        bytes memory data = abi.encodeWithSelector(bytes4(0x3b3b57de), bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                StandaloneReverseRegistrar.UnsupportedResolverProfile.selector,
                bytes4(0x3b3b57de)
            )
        );
        registrar.resolve(dnsEncodedName, data);
    }

    function testFuzz_resolve_revert_unsupportedResolverProfile(bytes4 selector) public {
        vm.assume(selector != INameResolver.name.selector);

        bytes memory dnsEncodedName = _buildDnsEncodedName(user1);
        bytes memory data = abi.encodeWithSelector(selector, bytes32(0));

        vm.expectRevert(
            abi.encodeWithSelector(
                StandaloneReverseRegistrar.UnsupportedResolverProfile.selector,
                selector
            )
        );
        registrar.resolve(dnsEncodedName, data);
    }

    function test_resolve_revert_unreachableName_wrongLength() public {
        // Create a name with wrong length (not PARENT_LENGTH + 41)
        bytes memory shortName = abi.encodePacked(uint8(10), "0123456789");
        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));

        vm.expectRevert(
            abi.encodeWithSelector(StandaloneReverseRegistrar.UnreachableName.selector, shortName)
        );
        registrar.resolve(shortName, data);
    }

    function test_resolve_revert_unreachableName_wrongParent() public {
        // Build name with correct length but wrong parent
        // 41 bytes for address part + wrong parent
        bytes memory addressPart = abi.encodePacked(
            uint8(40),
            "0000000000000000000000000000000000000001"
        );
        bytes memory wrongParent = abi.encodePacked(
            uint8(5),
            "wrong",
            uint8(7),
            "reverse",
            uint8(0)
        );
        bytes memory dnsEncodedName = abi.encodePacked(addressPart, wrongParent);

        // Ensure length matches expected
        uint256 expectedLength = registrar.PARENT_LENGTH() + 41;
        if (dnsEncodedName.length != expectedLength) {
            // Adjust to have correct length but wrong hash
            bytes memory padded = new bytes(expectedLength);
            for (uint256 i = 0; i < addressPart.length && i < expectedLength; i++) {
                padded[i] = addressPart[i];
            }
            dnsEncodedName = padded;
        }

        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));

        vm.expectRevert(
            abi.encodeWithSelector(
                StandaloneReverseRegistrar.UnreachableName.selector,
                dnsEncodedName
            )
        );
        registrar.resolve(dnsEncodedName, data);
    }

    ////////////////////////////////////////////////////////////////////////
    // _setName() Tests (via mock)
    ////////////////////////////////////////////////////////////////////////

    function test_setName_updatesMapping() public {
        string memory name_ = "test.eth";
        registrar.setName(user1, name_);

        string memory label = LibString.toAddressString(user1);
        bytes32 node = keccak256(
            abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
        );

        assertEq(registrar.name(node), name_, "Name should be stored");
    }

    function test_setName_emitsNameRegisteredEvent() public {
        string memory name_ = "alice.eth";
        string memory expectedLabel = LibString.toAddressString(user1);
        uint256 expectedTokenId = uint256(keccak256(abi.encodePacked(expectedLabel)));

        vm.expectEmit(true, false, false, true);
        emit IENSIP16.NameRegistered(
            expectedTokenId,
            expectedLabel,
            type(uint64).max,
            address(this),
            0
        );

        registrar.setName(user1, name_);
    }

    function test_setName_emitsResolverUpdatedEvent() public {
        string memory name_ = "bob.eth";
        string memory expectedLabel = LibString.toAddressString(user1);
        uint256 expectedTokenId = uint256(keccak256(abi.encodePacked(expectedLabel)));

        vm.expectEmit(true, false, false, true);
        emit IENSIP16.ResolverUpdated(expectedTokenId, address(registrar));

        registrar.setName(user1, name_);
    }

    function test_setName_emitsNameChangedEvent() public {
        string memory name_ = "carol.eth";
        string memory label = LibString.toAddressString(user1);
        bytes32 expectedNode = keccak256(
            abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
        );

        vm.expectEmit(true, false, false, true);
        emit INameResolver.NameChanged(expectedNode, name_);

        registrar.setName(user1, name_);
    }

    function test_setName_allEvents() public {
        string memory name_ = "dave.eth";

        vm.recordLogs();
        registrar.setName(user1, name_);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        // Should have 3 events: NameRegistered, ResolverUpdated, NameChanged
        assertEq(logs.length, 3, "Should emit 3 events");

        // Verify event topics
        assertEq(
            logs[0].topics[0],
            keccak256("NameRegistered(uint256,string,uint64,address,uint256)"),
            "First event should be NameRegistered"
        );
        assertEq(
            logs[1].topics[0],
            keccak256("ResolverUpdated(uint256,address)"),
            "Second event should be ResolverUpdated"
        );
        assertEq(
            logs[2].topics[0],
            keccak256("NameChanged(bytes32,string)"),
            "Third event should be NameChanged"
        );
    }

    function test_setName_canOverwrite() public {
        string memory firstName = "first.eth";
        string memory secondName = "second.eth";

        registrar.setName(user1, firstName);

        string memory label = LibString.toAddressString(user1);
        bytes32 node = keccak256(
            abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
        );

        assertEq(registrar.name(node), firstName, "First name should be set");

        registrar.setName(user1, secondName);
        assertEq(registrar.name(node), secondName, "Name should be overwritten");
    }

    function test_setName_emptyName() public {
        registrar.setName(user1, "");

        string memory label = LibString.toAddressString(user1);
        bytes32 node = keccak256(
            abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
        );

        assertEq(registrar.name(node), "", "Empty name should be stored");
    }

    function testFuzz_setName(address addr, string memory name_) public {
        registrar.setName(addr, name_);

        string memory label = LibString.toAddressString(addr);
        bytes32 node = keccak256(
            abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
        );

        assertEq(registrar.name(node), name_, "Name should be stored");
    }

    ////////////////////////////////////////////////////////////////////////
    // Integration Tests
    ////////////////////////////////////////////////////////////////////////

    function test_fullFlow_setAndResolve() public {
        string memory expectedName = "integration.eth";

        // Set name
        registrar.setName(user1, expectedName);

        // Resolve via resolve()
        bytes memory dnsEncodedName = _buildDnsEncodedName(user1);
        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));
        bytes memory result = registrar.resolve(dnsEncodedName, data);

        string memory resolvedName = abi.decode(result, (string));
        assertEq(resolvedName, expectedName, "Resolved name should match");

        // Also verify via direct name() call
        string memory label = LibString.toAddressString(user1);
        bytes32 node = keccak256(
            abi.encodePacked(registrar.PARENT_NODE(), keccak256(abi.encodePacked(label)))
        );
        assertEq(registrar.name(node), expectedName, "Direct name() should match");
    }

    function test_multipleUsers() public {
        string memory name1 = "user1.eth";
        string memory name2 = "user2.eth";

        registrar.setName(user1, name1);
        registrar.setName(user2, name2);

        bytes memory dnsEncodedName1 = _buildDnsEncodedName(user1);
        bytes memory dnsEncodedName2 = _buildDnsEncodedName(user2);
        bytes memory data = abi.encodeCall(INameResolver.name, (bytes32(0)));

        string memory resolved1 = abi.decode(registrar.resolve(dnsEncodedName1, data), (string));
        string memory resolved2 = abi.decode(registrar.resolve(dnsEncodedName2, data), (string));

        assertEq(resolved1, name1, "User1 name should match");
        assertEq(resolved2, name2, "User2 name should match");
    }

    function test_differentLabels() public {
        // Deploy registrars with different labels
        MockStandaloneReverseRegistrarImplementer ethRegistrar = new MockStandaloneReverseRegistrarImplementer(
                "default"
            );
        MockStandaloneReverseRegistrarImplementer opRegistrar = new MockStandaloneReverseRegistrarImplementer(
                "8000000a"
            );

        // Parent nodes should be different
        assertTrue(
            ethRegistrar.PARENT_NODE() != opRegistrar.PARENT_NODE(),
            "Parent nodes should differ"
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Helper Functions
    ////////////////////////////////////////////////////////////////////////

    function _buildDnsEncodedName(address addr) internal view returns (bytes memory) {
        string memory addrString = LibString.toAddressString(addr);

        bytes memory parent = abi.encodePacked(
            uint8(bytes(ETH_LABEL).length),
            ETH_LABEL,
            uint8(7),
            "reverse",
            uint8(0)
        );

        return abi.encodePacked(uint8(40), addrString, parent);
    }

    function _parseAddress(string memory str) internal pure returns (address) {
        bytes memory strBytes = bytes(str);
        require(strBytes.length == 40, "Invalid address length");

        uint160 result = 0;
        for (uint256 i = 0; i < 40; i++) {
            result = result * 16 + _hexCharToUint(strBytes[i]);
        }
        return address(result);
    }

    function _hexCharToUint(bytes1 c) internal pure returns (uint160) {
        if (c >= "0" && c <= "9") {
            return uint160(uint8(c) - uint8(bytes1("0")));
        }
        if (c >= "a" && c <= "f") {
            return uint160(uint8(c) - uint8(bytes1("a")) + 10);
        }
        if (c >= "A" && c <= "F") {
            return uint160(uint8(c) - uint8(bytes1("A")) + 10);
        }
        revert("Invalid hex char");
    }
}
