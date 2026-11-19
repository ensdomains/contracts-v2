// SPDX-License-Identifier: MIT
pragma solidity 0.8.27;

import {Test} from "forge-std/Test.sol";

import {Execution} from "nexus/types/DataTypes.sol";

import {HCAOperationHashLib} from "~src/hca/libraries/HCAOperationHashLib.sol";

import {OwnerSessionOperationHarness} from "./owner/OwnerSessionOperationHarness.sol";

/// @title HCA Packed Operation Decoder Proofs
/// @notice Checks assembly decoding and hashing against independent Solidity ABI encoding.
/// @dev The subject is the exact internal production library exposed by a thin entry harness.
///      One-action calldata lengths are 0, 1, 31, 32, 33, and 65 bytes as configured in halmos.toml;
///      two-action checks use two symbolic 32-byte payloads and allow arbitrary target aliasing.
///      Count-error shapes use concrete counts 0, 2, and 255. Underdeclared lengths are 0, 1, and 31;
///      every uint24 length greater than the 32-byte payload is checked. Mode admission belongs to the public
///      validator suites: this decoder intentionally preserves arbitrary two-byte mode values.
contract HCAOwnerSessionEncoding is Test {
    OwnerSessionOperationHarness internal decoder;

    /// @notice Deploys a wrapper that directly enters the unmodified production decoder.
    function setUp() public {
        decoder = new OwnerSessionOperationHarness();
    }

    /// @notice Every byte and target survives decoding, value remains zero, and the EIP-712 hash agrees.
    function check_singleExecutionRoundTrip(bytes2 mode, address target, bytes calldata data)
        public
        view
    {
        Execution[] memory expected = new Execution[](1);
        expected[0] = Execution(target, 0, data);
        bytes memory packed = abi.encodePacked(mode, uint8(1), target, uint24(data.length), data);
        _roundTrip(packed, bytes32(mode), expected);
    }

    /// @notice Two actions preserve order, including equal targets and equal or unequal payload words.
    function check_twoExecutionRoundTrip(
        bytes2 mode,
        address firstTarget,
        address secondTarget,
        bytes32 firstData,
        bytes32 secondData
    )
        public
        view
    {
        Execution[] memory expected = new Execution[](2);
        expected[0] = Execution(firstTarget, 0, abi.encodePacked(firstData));
        expected[1] = Execution(secondTarget, 0, abi.encodePacked(secondData));
        bytes memory packed =
            abi.encodePacked(
                mode,
                uint8(2),
                firstTarget,
                uint24(32),
                firstData,
                secondTarget,
                uint24(32),
                secondData
            );
        _roundTrip(packed, bytes32(mode), expected);
    }

    /// @notice The decoder represents an exact zero-action encoding; policy rejection is checked separately.
    function check_emptyOperationRoundTrip(bytes2 mode) public view {
        _roundTrip(abi.encodePacked(mode, uint8(0)), bytes32(mode), new Execution[](0));
    }

    /// @notice Every uint24 declared length beyond the actual 32-byte payload is rejected.
    function check_declaredLengthTooLong(
        bytes2 mode,
        address target,
        uint24 declaredLength,
        bytes32 data
    )
        public
        view
    {
        vm.assume(declaredLength > 32);
        _reject(abi.encodePacked(mode, uint8(1), target, declaredLength, data));
    }

    /// @notice Declared lengths zero, one, and 31 cannot hide the unconsumed part of a 32-byte payload.
    /// @dev Three explicit shapes avoid symbolic memory offsets unsupported by Halmos 0.3.3.
    function check_underdeclaredLengthRejected(
        bytes2 mode,
        address target,
        bytes32 data,
        uint8 shape
    )
        public
        view
    {
        vm.assume(shape <= 2);
        if (shape == 0)
            _reject(abi.encodePacked(mode, uint8(1), target, uint24(0), data));
        else if (shape == 1)
            _reject(abi.encodePacked(mode, uint8(1), target, uint24(1), data));
        else
            _reject(abi.encodePacked(mode, uint8(1), target, uint24(31), data));
    }

    /// @notice An appended byte cannot be ignored after an otherwise complete operation.
    function check_trailingByteRejected(bytes2 mode, address target, bytes32 data, bytes1 suffix)
        public
        view
    {
        _reject(abi.encodePacked(mode, uint8(1), target, uint24(32), data, suffix));
    }

    /// @notice A zero count cannot hide a complete execution following the header.
    function check_zeroCountCannotHideExecution(bytes2 mode, address target, bytes32 data)
        public
        view
    {
        _reject(abi.encodePacked(mode, uint8(0), target, uint24(32), data));
    }

    /// @notice A count of two cannot consume a batch containing only one execution.
    function check_missingSecondExecution(bytes2 mode, address target, bytes32 data) public view {
        _reject(abi.encodePacked(mode, uint8(2), target, uint24(32), data));
    }

    /// @notice The maximum representable count fails on the first missing execution rather than overreading.
    function check_maximumCountMissingExecution(bytes2 mode, address target, bytes32 data)
        public
        view
    {
        _reject(abi.encodePacked(mode, type(uint8).max, target, uint24(32), data));
    }

    /// @notice A two-byte mode alone is shorter than the required packed operation header.
    function check_truncatedOperationHeader(bytes2 mode) public view {
        _reject(abi.encodePacked(mode));
    }

    /// @notice A target without its complete three-byte calldata length is rejected.
    function check_truncatedExecutionHeader(bytes2 mode, address target, bytes2 partialLength)
        public
        view
    {
        _reject(abi.encodePacked(mode, uint8(1), target, partialLength));
    }

    /// @dev Requires full successful returndata, then compares all decoded fields and independent hashes.
    function _roundTrip(bytes memory packed, bytes32 mode, Execution[] memory expected)
        private
        view
    {
        (bool success, bytes memory result) =
            address(decoder).staticcall(
                abi.encodeCall(OwnerSessionOperationHarness.decodeAndHash, (packed))
            );
        assert(success);
        (HCAOperationHashLib.DecodedOperation memory actual, bytes32 actualHash) =
            abi.decode(result, (HCAOperationHashLib.DecodedOperation, bytes32));
        assert(actual.mode == mode);
        assert(actual.executions.length == expected.length);
        bytes32[] memory executionHashes = new bytes32[](expected.length);
        for (uint256 i; i < expected.length; ++i) {
            assert(actual.executions[i].target == expected[i].target);
            assert(actual.executions[i].value == 0);
            assert(actual.executions[i].callData.length == expected[i].callData.length);
            assert(keccak256(actual.executions[i].callData) == keccak256(expected[i].callData));
            executionHashes[i] = keccak256(
                abi.encode(
                    HCAOperationHashLib.EXECUTION_TYPEHASH,
                    expected[i].target,
                    uint256(0),
                    keccak256(expected[i].callData)
                )
            );
        }
        bytes32 expectedHash =
            keccak256(
                abi.encode(
                    HCAOperationHashLib.OPERATION_TYPEHASH,
                    mode,
                    keccak256(abi.encodePacked(executionHashes))
                )
            );
        assert(actualHash == expectedHash);
    }

    /// @dev Asserts the exact decoder revert instead of allowing a reverted assertion path to disappear.
    function _reject(bytes memory packed) private view {
        (bool success, bytes memory result) =
            address(decoder).staticcall(
                abi.encodeCall(OwnerSessionOperationHarness.decodeAndHash, (packed))
            );
        assert(!success);
        assert(result.length == 4);
        assert(bytes4(result) == HCAOperationHashLib.InvalidOperationEncoding.selector);
    }
}
