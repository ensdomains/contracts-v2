// SPDX-License-Identifier: MIT
pragma solidity ^0.8.13;

// solhint-disable private-vars-leading-underscore, state-visibility, func-name-mixedcase, namechain/ordering, one-contract-per-file, namechain/import-order-separation, gas-small-strings, gas-strict-inequalities, gas-increment-by-one, gas-custom-errors

import {Test} from "forge-std/Test.sol";

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {ChainIdsBuilderLib} from "~src/reverse-registrar/libraries/ChainIdsBuilderLib.sol";

/// @dev Harness that exposes the internal library function via an external call.
///      Memory arrays in the test are ABI-encoded as calldata automatically.
contract ChainIdsBuilderLibHarness {
    function validateAndBuild(
        uint256[] calldata chainIds,
        uint256 currentChainId
    ) external pure returns (string memory) {
        return ChainIdsBuilderLib.validateAndBuild(chainIds, currentChainId);
    }
}

contract ChainIdsBuilderLibTest is Test {
    using Strings for uint256;

    ChainIdsBuilderLibHarness harness;

    function setUp() public {
        harness = new ChainIdsBuilderLibHarness();
    }

    /// @dev Naive O(n²) reference implementation using string.concat.
    function _referenceImpl(uint256[] memory ids) internal pure returns (string memory) {
        string memory result = ids[0].toString();
        for (uint256 i = 1; i < ids.length; i++) {
            result = string.concat(result, ", ", ids[i].toString());
        }
        return result;
    }

    ////////////////////////////////////////////////////////////////////////
    // Happy Path – Single Element
    ////////////////////////////////////////////////////////////////////////

    function test_singleChainId() public view {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 10;
        assertEq(harness.validateAndBuild(ids, 10), "10");
    }

    function test_singleChainId_zero() public view {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 0;
        assertEq(harness.validateAndBuild(ids, 0), "0");
    }

    function test_singleChainId_one() public view {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        assertEq(harness.validateAndBuild(ids, 1), "1");
    }

    function test_singleChainId_maxUint256() public view {
        uint256[] memory ids = new uint256[](1);
        ids[0] = type(uint256).max;
        assertEq(harness.validateAndBuild(ids, type(uint256).max), type(uint256).max.toString());
    }

    ////////////////////////////////////////////////////////////////////////
    // Happy Path – Two Elements
    ////////////////////////////////////////////////////////////////////////

    function test_twoChainIds() public view {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 1;
        ids[1] = 10;
        assertEq(harness.validateAndBuild(ids, 10), "1, 10");
    }

    function test_twoChainIds_zeroAndOne() public view {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 1;
        assertEq(harness.validateAndBuild(ids, 0), "0, 1");
    }

    function test_twoChainIds_consecutiveLarge() public view {
        uint256[] memory ids = new uint256[](2);
        ids[0] = type(uint256).max - 1;
        ids[1] = type(uint256).max;
        string memory expected = string.concat(
            (type(uint256).max - 1).toString(),
            ", ",
            type(uint256).max.toString()
        );
        assertEq(harness.validateAndBuild(ids, type(uint256).max), expected);
    }

    ////////////////////////////////////////////////////////////////////////
    // Happy Path – Multiple Elements
    ////////////////////////////////////////////////////////////////////////

    function test_multipleChainIds_currentAtStart() public view {
        uint256[] memory ids = new uint256[](4);
        ids[0] = 1;
        ids[1] = 10;
        ids[2] = 8453;
        ids[3] = 42161;
        assertEq(harness.validateAndBuild(ids, 1), "1, 10, 8453, 42161");
    }

    function test_multipleChainIds_currentInMiddle() public view {
        uint256[] memory ids = new uint256[](4);
        ids[0] = 1;
        ids[1] = 10;
        ids[2] = 8453;
        ids[3] = 42161;
        assertEq(harness.validateAndBuild(ids, 10), "1, 10, 8453, 42161");
    }

    function test_multipleChainIds_currentAtEnd() public view {
        uint256[] memory ids = new uint256[](4);
        ids[0] = 1;
        ids[1] = 10;
        ids[2] = 8453;
        ids[3] = 42161;
        assertEq(harness.validateAndBuild(ids, 42161), "1, 10, 8453, 42161");
    }

    function test_consecutiveNumbers() public view {
        uint256[] memory ids = new uint256[](5);
        ids[0] = 1;
        ids[1] = 2;
        ids[2] = 3;
        ids[3] = 4;
        ids[4] = 5;
        assertEq(harness.validateAndBuild(ids, 3), "1, 2, 3, 4, 5");
    }

    function test_chainIdZeroWithOthers() public view {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 0;
        ids[1] = 1;
        ids[2] = 10;
        assertEq(harness.validateAndBuild(ids, 0), "0, 1, 10");
    }

    function test_maxUint256WithOthers() public view {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 42161;
        ids[2] = type(uint256).max;
        string memory expected = string.concat("1, 42161, ", type(uint256).max.toString());
        assertEq(harness.validateAndBuild(ids, 1), expected);
    }

    ////////////////////////////////////////////////////////////////////////
    // Happy Path – Large Array (matches reference implementation)
    ////////////////////////////////////////////////////////////////////////

    function test_largeArray_matchesReference() public view {
        uint256[] memory ids = new uint256[](20);
        ids[0] = 1;
        ids[1] = 5;
        ids[2] = 10;
        ids[3] = 25;
        ids[4] = 56;
        ids[5] = 100;
        ids[6] = 137;
        ids[7] = 250;
        ids[8] = 324;
        ids[9] = 1101;
        ids[10] = 5000;
        ids[11] = 8453;
        ids[12] = 34443;
        ids[13] = 42161;
        ids[14] = 42170;
        ids[15] = 43114;
        ids[16] = 59144;
        ids[17] = 81457;
        ids[18] = 534352;
        ids[19] = 7777777;

        string memory result = harness.validateAndBuild(ids, 10);
        string memory expected = _referenceImpl(ids);
        assertEq(result, expected);
    }

    function test_largeArray_explicitString() public view {
        uint256[] memory ids = new uint256[](6);
        ids[0] = 1;
        ids[1] = 10;
        ids[2] = 137;
        ids[3] = 8453;
        ids[4] = 42161;
        ids[5] = 534352;
        assertEq(harness.validateAndBuild(ids, 10), "1, 10, 137, 8453, 42161, 534352");
    }

    ////////////////////////////////////////////////////////////////////////
    // Happy Path – Typical Real-World Chain IDs
    ////////////////////////////////////////////////////////////////////////

    function test_realWorldChainIds_ethereumAndL2s() public view {
        uint256[] memory ids = new uint256[](5);
        ids[0] = 1; // Ethereum
        ids[1] = 10; // Optimism
        ids[2] = 137; // Polygon
        ids[3] = 8453; // Base
        ids[4] = 42161; // Arbitrum
        assertEq(harness.validateAndBuild(ids, 1), "1, 10, 137, 8453, 42161");
    }

    ////////////////////////////////////////////////////////////////////////
    // Error Tests – Empty Array
    ////////////////////////////////////////////////////////////////////////

    function test_revert_emptyArray() public {
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(ChainIdsBuilderLib.CurrentChainNotFound.selector, 10)
        );
        harness.validateAndBuild(ids, 10);
    }

    function test_revert_emptyArray_chainIdZero() public {
        uint256[] memory ids = new uint256[](0);
        vm.expectRevert(
            abi.encodeWithSelector(ChainIdsBuilderLib.CurrentChainNotFound.selector, 0)
        );
        harness.validateAndBuild(ids, 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // Error Tests – Current Chain Not Found
    ////////////////////////////////////////////////////////////////////////

    function test_revert_currentChainNotFound_singleElement() public {
        uint256[] memory ids = new uint256[](1);
        ids[0] = 1;
        vm.expectRevert(
            abi.encodeWithSelector(ChainIdsBuilderLib.CurrentChainNotFound.selector, 10)
        );
        harness.validateAndBuild(ids, 10);
    }

    function test_revert_currentChainNotFound_multipleElements() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 8453;
        ids[2] = 42161;
        vm.expectRevert(
            abi.encodeWithSelector(ChainIdsBuilderLib.CurrentChainNotFound.selector, 10)
        );
        harness.validateAndBuild(ids, 10);
    }

    function test_revert_currentChainNotFound_neighbourValues() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 9;
        ids[1] = 11;
        vm.expectRevert(
            abi.encodeWithSelector(ChainIdsBuilderLib.CurrentChainNotFound.selector, 10)
        );
        harness.validateAndBuild(ids, 10);
    }

    ////////////////////////////////////////////////////////////////////////
    // Error Tests – Not Ascending
    ////////////////////////////////////////////////////////////////////////

    function test_revert_notAscending_equalPair() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 10;
        ids[1] = 10;
        vm.expectRevert(ChainIdsBuilderLib.ChainIdsNotAscending.selector);
        harness.validateAndBuild(ids, 10);
    }

    function test_revert_notAscending_descendingPair() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 42161;
        ids[1] = 10;
        vm.expectRevert(ChainIdsBuilderLib.ChainIdsNotAscending.selector);
        harness.validateAndBuild(ids, 10);
    }

    function test_revert_notAscending_equalInMiddle() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 10;
        ids[2] = 10;
        vm.expectRevert(ChainIdsBuilderLib.ChainIdsNotAscending.selector);
        harness.validateAndBuild(ids, 10);
    }

    function test_revert_notAscending_descendingInMiddle() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 42161;
        ids[2] = 10;
        vm.expectRevert(ChainIdsBuilderLib.ChainIdsNotAscending.selector);
        harness.validateAndBuild(ids, 10);
    }

    function test_revert_notAscending_fullyDescending() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 42161;
        ids[1] = 10;
        ids[2] = 1;
        vm.expectRevert(ChainIdsBuilderLib.ChainIdsNotAscending.selector);
        harness.validateAndBuild(ids, 10);
    }

    function test_revert_notAscending_duplicateAtStart() public {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 1;
        ids[2] = 10;
        vm.expectRevert(ChainIdsBuilderLib.ChainIdsNotAscending.selector);
        harness.validateAndBuild(ids, 10);
    }

    function test_revert_notAscending_duplicateZeros() public {
        uint256[] memory ids = new uint256[](2);
        ids[0] = 0;
        ids[1] = 0;
        vm.expectRevert(ChainIdsBuilderLib.ChainIdsNotAscending.selector);
        harness.validateAndBuild(ids, 0);
    }

    ////////////////////////////////////////////////////////////////////////
    // Error Tests – Ascending check fires before CurrentChainNotFound
    ////////////////////////////////////////////////////////////////////////

    function test_revert_notAscending_firesBeforeCurrentNotFound() public {
        // Array is not ascending AND doesn't contain current chain.
        // ChainIdsNotAscending should fire first because the loop breaks early.
        uint256[] memory ids = new uint256[](3);
        ids[0] = 100;
        ids[1] = 50;
        ids[2] = 200;
        vm.expectRevert(ChainIdsBuilderLib.ChainIdsNotAscending.selector);
        harness.validateAndBuild(ids, 999);
    }

    ////////////////////////////////////////////////////////////////////////
    // Fuzz Tests – Single Element
    ////////////////////////////////////////////////////////////////////////

    function testFuzz_singleElement(uint256 chainId) public view {
        uint256[] memory ids = new uint256[](1);
        ids[0] = chainId;
        assertEq(harness.validateAndBuild(ids, chainId), chainId.toString());
    }

    ////////////////////////////////////////////////////////////////////////
    // Fuzz Tests – Two Elements (matches reference)
    ////////////////////////////////////////////////////////////////////////

    function testFuzz_twoElements(uint256 a, uint256 gap) public view {
        vm.assume(a < type(uint256).max);
        gap = bound(gap, 1, type(uint256).max - a);
        uint256 b = a + gap;

        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;

        string memory expected = _referenceImpl(ids);
        assertEq(harness.validateAndBuild(ids, a), expected);
    }

    ////////////////////////////////////////////////////////////////////////
    // Fuzz Tests – Three Elements (matches reference)
    ////////////////////////////////////////////////////////////////////////

    function testFuzz_threeElements(uint256 a, uint256 gap1, uint256 gap2) public view {
        vm.assume(a < type(uint256).max - 1);
        gap1 = bound(gap1, 1, (type(uint256).max - a) / 2);
        uint256 b = a + gap1;
        gap2 = bound(gap2, 1, type(uint256).max - b);
        uint256 c = b + gap2;

        uint256[] memory ids = new uint256[](3);
        ids[0] = a;
        ids[1] = b;
        ids[2] = c;

        string memory expected = _referenceImpl(ids);
        // Use middle element as current chain ID
        assertEq(harness.validateAndBuild(ids, b), expected);
    }

    ////////////////////////////////////////////////////////////////////////
    // Fuzz Tests – Not Ascending (always reverts)
    ////////////////////////////////////////////////////////////////////////

    function testFuzz_revert_notAscending(uint256 a, uint256 b) public {
        vm.assume(b <= a);
        uint256[] memory ids = new uint256[](2);
        ids[0] = a;
        ids[1] = b;
        vm.expectRevert(ChainIdsBuilderLib.ChainIdsNotAscending.selector);
        harness.validateAndBuild(ids, a);
    }

    ////////////////////////////////////////////////////////////////////////
    // Fuzz Tests – Current Chain Not Found (always reverts)
    ////////////////////////////////////////////////////////////////////////

    function testFuzz_revert_currentNotFound(uint256 current, uint256 chainId) public {
        vm.assume(current != chainId);
        uint256[] memory ids = new uint256[](1);
        ids[0] = chainId;
        vm.expectRevert(
            abi.encodeWithSelector(ChainIdsBuilderLib.CurrentChainNotFound.selector, current)
        );
        harness.validateAndBuild(ids, current);
    }

    ////////////////////////////////////////////////////////////////////////
    // Fuzz Test – Larger Array (matches reference, random ascending values)
    ////////////////////////////////////////////////////////////////////////

    function testFuzz_fiveElements_matchesReference(
        uint256 a,
        uint256 g1,
        uint256 g2,
        uint256 g3,
        uint256 g4
    ) public view {
        vm.assume(a < type(uint256).max / 5);
        g1 = bound(g1, 1, type(uint256).max / 5);
        g2 = bound(g2, 1, type(uint256).max / 5);
        g3 = bound(g3, 1, type(uint256).max / 5);
        g4 = bound(g4, 1, type(uint256).max / 5);

        uint256[] memory ids = new uint256[](5);
        ids[0] = a;
        ids[1] = a + g1;
        ids[2] = a + g1 + g2;
        ids[3] = a + g1 + g2 + g3;
        ids[4] = a + g1 + g2 + g3 + g4;

        string memory expected = _referenceImpl(ids);
        assertEq(harness.validateAndBuild(ids, ids[2]), expected);
    }

    ////////////////////////////////////////////////////////////////////////
    // Edge Case – Memory Safety (subsequent allocations are not corrupted)
    ////////////////////////////////////////////////////////////////////////

    function test_memorySafety_subsequentAllocations() public view {
        uint256[] memory ids = new uint256[](3);
        ids[0] = 1;
        ids[1] = 10;
        ids[2] = 8453;

        string memory result = harness.validateAndBuild(ids, 10);

        // Perform another allocation after the library call and verify both are intact.
        string memory other = "hello world";

        assertEq(result, "1, 10, 8453");
        assertEq(other, "hello world");
    }

    ////////////////////////////////////////////////////////////////////////
    // Edge Case – Digit Boundary Values (powers of 10)
    ////////////////////////////////////////////////////////////////////////

    function test_powersOfTen() public view {
        uint256[] memory ids = new uint256[](8);
        ids[0] = 1;
        ids[1] = 10;
        ids[2] = 100;
        ids[3] = 1000;
        ids[4] = 10000;
        ids[5] = 100000;
        ids[6] = 1000000;
        ids[7] = 10000000;

        string memory result = harness.validateAndBuild(ids, 1);
        assertEq(result, "1, 10, 100, 1000, 10000, 100000, 1000000, 10000000");
    }

    function test_justBelowPowersOfTen() public view {
        uint256[] memory ids = new uint256[](4);
        ids[0] = 9;
        ids[1] = 99;
        ids[2] = 999;
        ids[3] = 9999;

        string memory result = harness.validateAndBuild(ids, 9);
        assertEq(result, "9, 99, 999, 9999");
    }

    ////////////////////////////////////////////////////////////////////////
    // Edge Case – Wide Spread of Digit Lengths
    ////////////////////////////////////////////////////////////////////////

    function test_wideSpreadDigitLengths() public view {
        uint256[] memory ids = new uint256[](4);
        ids[0] = 0;
        ids[1] = 7;
        ids[2] = 42161;
        ids[3] = 100000000000000000; // 1e17

        string memory result = harness.validateAndBuild(ids, 0);
        string memory expected = _referenceImpl(ids);
        assertEq(result, expected);
    }
}
