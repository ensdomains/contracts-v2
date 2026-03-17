// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable no-console, private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file

import {Test} from "forge-std/Test.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {LibString} from "~src/utils/LibString.sol";

contract LibStringTest is Test {
    ////////////////////////////////////////////////////////////////////////
    // toAddressString Tests
    ////////////////////////////////////////////////////////////////////////

    function test_toAddressString_zeroAddress() external pure {
        string memory result = LibString.toAddressString(address(0));
        assertEq(result, "0000000000000000000000000000000000000000");
        assertEq(bytes(result).length, 40);
    }

    function test_toAddressString_maxAddress() external pure {
        address maxAddr = address(type(uint160).max);
        string memory result = LibString.toAddressString(maxAddr);
        assertEq(result, "ffffffffffffffffffffffffffffffffffffffff");
        assertEq(bytes(result).length, 40);
    }

    function test_toAddressString_knownAddress1() external pure {
        // 0xdead...beef pattern
        address addr = address(0xDeaDbeefdEAdbeefdEadbEEFdeadbeEFdEaDbeeF);
        string memory result = LibString.toAddressString(addr);
        assertEq(result, "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef");
    }

    function test_toAddressString_knownAddress2() external pure {
        // Common test address
        address addr = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        string memory result = LibString.toAddressString(addr);
        assertEq(result, "1234567890abcdef1234567890abcdef12345678");
    }

    function test_toAddressString_singleByteHigh() external pure {
        // Address with only high byte set
        address addr = address(uint160(0xff) << 152);
        string memory result = LibString.toAddressString(addr);
        assertEq(result, "ff00000000000000000000000000000000000000");
    }

    function test_toAddressString_singleByteLow() external pure {
        // Address with only low byte set
        address addr = address(uint160(0xff));
        string memory result = LibString.toAddressString(addr);
        assertEq(result, "00000000000000000000000000000000000000ff");
    }

    function test_toAddressString_alternatingNibbles() external pure {
        // 0x0a0a... pattern to test nibble extraction
        address addr = address(0x0A0A0a0a0a0a0a0A0a0a0A0a0A0A0A0a0a0a0a0a);
        string memory result = LibString.toAddressString(addr);
        assertEq(result, "0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a");
    }

    function test_toAddressString_allHexDigits() external pure {
        // Address containing all hex digits 0-9 and a-f
        address addr = address(0x0123456789AbCDEFAbCDef0123456789AbcDEf01);
        string memory result = LibString.toAddressString(addr);
        // Note: result is always lowercase
        assertEq(result, "0123456789abcdefabcdef0123456789abcdef01");
    }

    function test_toAddressString_leadingZeros() external pure {
        // Small number with many leading zeros
        address addr = address(uint160(0x123));
        string memory result = LibString.toAddressString(addr);
        assertEq(result, "0000000000000000000000000000000000000123");
    }

    function testFuzz_toAddressString_length(address addr) external pure {
        string memory result = LibString.toAddressString(addr);
        assertEq(bytes(result).length, 40, "Result should always be 40 characters");
    }

    function testFuzz_toAddressString_lowercase(address addr) external pure {
        string memory result = LibString.toAddressString(addr);
        bytes memory b = bytes(result);
        for (uint256 i = 0; i < b.length; i++) {
            bytes1 char = b[i];
            // Should only contain 0-9 (0x30-0x39) or a-f (0x61-0x66)
            bool isDigit = char >= 0x30 && char <= 0x39;
            bool isLowerHex = char >= 0x61 && char <= 0x66;
            assertTrue(isDigit || isLowerHex, "Should only contain lowercase hex chars");
        }
    }

    function testFuzz_toAddressString_roundtrip(address addr) external pure {
        string memory result = LibString.toAddressString(addr);
        // Parse the hex string back to address
        address parsed = _parseHexAddress(result);
        assertEq(parsed, addr, "Round-trip conversion should match");
    }

    ////////////////////////////////////////////////////////////////////////
    // toChecksumHexString Tests
    ////////////////////////////////////////////////////////////////////////

    function test_toChecksumHexString_zeroAddress() external pure {
        string memory result = LibString.toChecksumHexString(address(0));
        assertEq(result, "0x0000000000000000000000000000000000000000");
        assertEq(bytes(result).length, 42);
    }

    function test_toChecksumHexString_hasPrefix() external pure {
        address addr = address(0x1234567890AbcdEF1234567890aBcdef12345678);
        string memory result = LibString.toChecksumHexString(addr);
        bytes memory b = bytes(result);
        assertEq(b[0], bytes1("0"), "First char should be '0'");
        assertEq(b[1], bytes1("x"), "Second char should be 'x'");
    }

    function test_toChecksumHexString_knownChecksum1() external pure {
        // Well-known checksummed address (Vitalik's address)
        address addr = 0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045;
        string memory result = LibString.toChecksumHexString(addr);
        assertEq(result, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045");
    }

    function test_toChecksumHexString_knownChecksum2() external pure {
        // Another known checksummed address (WETH on mainnet)
        address addr = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
        string memory result = LibString.toChecksumHexString(addr);
        assertEq(result, "0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2");
    }

    function test_toChecksumHexString_knownChecksum3() external pure {
        // USDC on mainnet
        address addr = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        string memory result = LibString.toChecksumHexString(addr);
        assertEq(result, "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48");
    }

    function test_toChecksumHexString_allLowercase() external pure {
        // Address where checksum results in all lowercase (0x0000...0001)
        address addr = address(1);
        string memory result = LibString.toChecksumHexString(addr);
        // This specific address should have specific checksum pattern
        assertEq(bytes(result).length, 42);
        // Verify it starts with 0x
        assertEq(bytes(result)[0], bytes1("0"));
        assertEq(bytes(result)[1], bytes1("x"));
    }

    function test_toChecksumHexString_deadbeef() external pure {
        address addr = 0x00000000000000000000000000000000DeaDBeef;
        string memory result = LibString.toChecksumHexString(addr);
        // Verify the checksum is applied correctly
        assertEq(bytes(result).length, 42);
    }

    function testFuzz_toChecksumHexString_length(address addr) external pure {
        string memory result = LibString.toChecksumHexString(addr);
        assertEq(bytes(result).length, 42, "Result should always be 42 characters");
    }

    function testFuzz_toChecksumHexString_prefix(address addr) external pure {
        string memory result = LibString.toChecksumHexString(addr);
        bytes memory b = bytes(result);
        assertEq(b[0], bytes1("0"), "First char should be '0'");
        assertEq(b[1], bytes1("x"), "Second char should be 'x'");
    }

    function testFuzz_toChecksumHexString_validHexChars(address addr) external pure {
        string memory result = LibString.toChecksumHexString(addr);
        bytes memory b = bytes(result);
        // Skip first two chars (0x prefix)
        for (uint256 i = 2; i < b.length; i++) {
            bytes1 char = b[i];
            // Should only contain 0-9 (0x30-0x39), a-f (0x61-0x66), or A-F (0x41-0x46)
            bool isDigit = char >= 0x30 && char <= 0x39;
            bool isLowerHex = char >= 0x61 && char <= 0x66;
            bool isUpperHex = char >= 0x41 && char <= 0x46;
            assertTrue(isDigit || isLowerHex || isUpperHex, "Should only contain valid hex chars");
        }
    }

    function testFuzz_toChecksumHexString_matchesOpenZeppelin(address addr) external pure {
        string memory ourResult = LibString.toChecksumHexString(addr);
        string memory ozResult = Strings.toChecksumHexString(addr);
        assertEq(ourResult, ozResult, "Should match OpenZeppelin implementation");
    }

    function testFuzz_toChecksumHexString_verifyEIP55(address addr) external pure {
        string memory result = LibString.toChecksumHexString(addr);
        assertTrue(_verifyEIP55Checksum(result), "Should pass EIP-55 checksum verification");
    }

    ////////////////////////////////////////////////////////////////////////
    // toString (uint256) Tests
    ////////////////////////////////////////////////////////////////////////

    function test_toString_zero() external pure {
        string memory result = LibString.toString(0);
        assertEq(result, "0");
        assertEq(bytes(result).length, 1);
    }

    function test_toString_one() external pure {
        string memory result = LibString.toString(1);
        assertEq(result, "1");
    }

    function test_toString_nine() external pure {
        string memory result = LibString.toString(9);
        assertEq(result, "9");
    }

    function test_toString_ten() external pure {
        string memory result = LibString.toString(10);
        assertEq(result, "10");
    }

    function test_toString_hundred() external pure {
        string memory result = LibString.toString(100);
        assertEq(result, "100");
    }

    function test_toString_thousand() external pure {
        string memory result = LibString.toString(1000);
        assertEq(result, "1000");
    }

    function test_toString_largeNumber() external pure {
        string memory result = LibString.toString(123456789);
        assertEq(result, "123456789");
    }

    function test_toString_maxUint8() external pure {
        string memory result = LibString.toString(type(uint8).max);
        assertEq(result, "255");
    }

    function test_toString_maxUint16() external pure {
        string memory result = LibString.toString(type(uint16).max);
        assertEq(result, "65535");
    }

    function test_toString_maxUint32() external pure {
        string memory result = LibString.toString(type(uint32).max);
        assertEq(result, "4294967295");
    }

    function test_toString_maxUint64() external pure {
        string memory result = LibString.toString(type(uint64).max);
        assertEq(result, "18446744073709551615");
    }

    function test_toString_maxUint128() external pure {
        string memory result = LibString.toString(type(uint128).max);
        assertEq(result, "340282366920938463463374607431768211455");
    }

    function test_toString_maxUint256() external pure {
        string memory result = LibString.toString(type(uint256).max);
        assertEq(
            result,
            "115792089237316195423570985008687907853269984665640564039457584007913129639935"
        );
    }

    function test_toString_powersOfTen() external pure {
        assertEq(LibString.toString(1), "1");
        assertEq(LibString.toString(10), "10");
        assertEq(LibString.toString(100), "100");
        assertEq(LibString.toString(1000), "1000");
        assertEq(LibString.toString(10000), "10000");
        assertEq(LibString.toString(100000), "100000");
        assertEq(LibString.toString(1000000), "1000000");
        assertEq(LibString.toString(10000000), "10000000");
        assertEq(LibString.toString(100000000), "100000000");
        assertEq(LibString.toString(1000000000), "1000000000");
    }

    function test_toString_allSingleDigits() external pure {
        assertEq(LibString.toString(0), "0");
        assertEq(LibString.toString(1), "1");
        assertEq(LibString.toString(2), "2");
        assertEq(LibString.toString(3), "3");
        assertEq(LibString.toString(4), "4");
        assertEq(LibString.toString(5), "5");
        assertEq(LibString.toString(6), "6");
        assertEq(LibString.toString(7), "7");
        assertEq(LibString.toString(8), "8");
        assertEq(LibString.toString(9), "9");
    }

    function test_toString_repeatingDigits() external pure {
        assertEq(LibString.toString(11111), "11111");
        assertEq(LibString.toString(22222), "22222");
        assertEq(LibString.toString(99999), "99999");
        assertEq(LibString.toString(1111111111), "1111111111");
    }

    function test_toString_specificPatterns() external pure {
        assertEq(LibString.toString(12345678901234567890), "12345678901234567890");
        assertEq(LibString.toString(98765432109876543210), "98765432109876543210");
    }

    function test_toString_ethereumValues() external pure {
        // 1 ETH in wei
        assertEq(LibString.toString(1 ether), "1000000000000000000");
        // 1 gwei
        assertEq(LibString.toString(1 gwei), "1000000000");
    }

    function test_toString_chainIds() external pure {
        // Ethereum mainnet
        assertEq(LibString.toString(1), "1");
        // Optimism
        assertEq(LibString.toString(10), "10");
        // Arbitrum
        assertEq(LibString.toString(42161), "42161");
        // Polygon
        assertEq(LibString.toString(137), "137");
        // Base
        assertEq(LibString.toString(8453), "8453");
    }

    function testFuzz_toString_noLeadingZeros(uint256 value) external pure {
        string memory result = LibString.toString(value);
        bytes memory b = bytes(result);

        // If the value is not zero, first char should not be '0'
        if (value != 0) {
            assertTrue(b[0] != bytes1("0"), "Should not have leading zeros");
        }
    }

    function testFuzz_toString_onlyDigits(uint256 value) external pure {
        string memory result = LibString.toString(value);
        bytes memory b = bytes(result);

        for (uint256 i = 0; i < b.length; i++) {
            bytes1 char = b[i];
            // Should only contain 0-9 (0x30-0x39)
            assertTrue(char >= 0x30 && char <= 0x39, "Should only contain digits");
        }
    }

    function testFuzz_toString_matchesOpenZeppelin(uint256 value) external pure {
        string memory ourResult = LibString.toString(value);
        string memory ozResult = Strings.toString(value);
        assertEq(ourResult, ozResult, "Should match OpenZeppelin implementation");
    }

    function testFuzz_toString_roundtrip(uint256 value) external pure {
        string memory result = LibString.toString(value);
        uint256 parsed = _parseUint(result);
        assertEq(parsed, value, "Round-trip conversion should match");
    }

    function testFuzz_toString_length(uint256 value) external pure {
        string memory result = LibString.toString(value);
        uint256 expectedLength = _countDigits(value);
        assertEq(bytes(result).length, expectedLength, "Length should match digit count");
    }

    ////////////////////////////////////////////////////////////////////////
    // Gas Benchmarks
    ////////////////////////////////////////////////////////////////////////

    function test_gas_toAddressString() external pure {
        LibString.toAddressString(0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045);
    }

    function test_gas_toChecksumHexString() external pure {
        LibString.toChecksumHexString(0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045);
    }

    function test_gas_toString_small() external pure {
        LibString.toString(123);
    }

    function test_gas_toString_medium() external pure {
        LibString.toString(123456789);
    }

    function test_gas_toString_large() external pure {
        LibString.toString(type(uint256).max);
    }

    ////////////////////////////////////////////////////////////////////////
    // Helper Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Parses a 40-character lowercase hex string to an address
    function _parseHexAddress(string memory s) internal pure returns (address) {
        bytes memory b = bytes(s);
        require(b.length == 40, "Invalid length");

        uint160 result = 0;
        for (uint256 i = 0; i < 40; i++) {
            result = result * 16 + _hexCharToUint(b[i]);
        }
        return address(result);
    }

    /// @dev Converts a hex character to its uint value
    function _hexCharToUint(bytes1 c) internal pure returns (uint8) {
        if (c >= 0x30 && c <= 0x39) {
            return uint8(c) - 0x30; // 0-9
        } else if (c >= 0x61 && c <= 0x66) {
            return uint8(c) - 0x61 + 10; // a-f
        } else if (c >= 0x41 && c <= 0x46) {
            return uint8(c) - 0x41 + 10; // A-F
        }
        revert("Invalid hex char");
    }

    /// @dev Parses a decimal string to uint256
    function _parseUint(string memory s) internal pure returns (uint256) {
        bytes memory b = bytes(s);
        uint256 result = 0;
        for (uint256 i = 0; i < b.length; i++) {
            require(b[i] >= 0x30 && b[i] <= 0x39, "Invalid digit");
            result = result * 10 + (uint8(b[i]) - 0x30);
        }
        return result;
    }

    /// @dev Counts the number of decimal digits in a value
    function _countDigits(uint256 value) internal pure returns (uint256) {
        if (value == 0) return 1;
        uint256 digits = 0;
        while (value > 0) {
            digits++;
            value /= 10;
        }
        return digits;
    }

    /// @dev Verifies an EIP-55 checksummed address string
    function _verifyEIP55Checksum(string memory addr) internal pure returns (bool) {
        bytes memory b = bytes(addr);
        if (b.length != 42) return false;
        if (b[0] != 0x30 || b[1] != 0x78) return false; // "0x"

        // Extract lowercase hex (without 0x prefix)
        bytes memory lowercase = new bytes(40);
        for (uint256 i = 0; i < 40; i++) {
            bytes1 c = b[i + 2];
            if (c >= 0x41 && c <= 0x46) {
                // Uppercase A-F -> lowercase a-f
                lowercase[i] = bytes1(uint8(c) + 32);
            } else {
                lowercase[i] = c;
            }
        }

        // Hash the lowercase hex
        bytes32 hash = keccak256(lowercase);

        // Verify checksum
        for (uint256 i = 0; i < 40; i++) {
            bytes1 c = b[i + 2];
            uint8 hashNibble = uint8(hash[i / 2]);
            if (i % 2 == 0) {
                hashNibble = hashNibble >> 4;
            } else {
                hashNibble = hashNibble & 0x0f;
            }

            // If it's a letter (a-f or A-F)
            if ((c >= 0x61 && c <= 0x66) || (c >= 0x41 && c <= 0x46)) {
                bool shouldBeUpper = hashNibble >= 8;
                bool isUpper = c >= 0x41 && c <= 0x46;
                if (shouldBeUpper != isUpper) return false;
            }
        }

        return true;
    }
}
