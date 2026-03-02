// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Test} from "forge-std/Test.sol";

import {WrappedErrorLib} from "~src/utils/WrappedErrorLib.sol";

contract MigrationErrorsTest is Test {
    error TypedError(uint256, string);

    function wrapAndRevert(bytes memory v) external pure {
        WrappedErrorLib.wrapAndRevert(v);
    }

    function test_selector() external pure {
        assertEq(
            WrappedErrorLib.ERROR_STRING_SELECTOR,
            bytes4(abi.encodeWithSignature("Error(string)"))
        );
    }

    function test_prefix() external pure {
        bytes memory v = WrappedErrorLib.wrap(hex"12345678");
        assembly {
            v := add(v, 4) // skip selector
        }
        assertEq(
            abi.decode(v, (bytes)),
            abi.encodePacked(WrappedErrorLib.WRAPPED_ERROR_PREFIX, "12345678")
        );
    }

    function test_wrap(bytes calldata v) external pure {
        vm.assume(bytes4(v) != WrappedErrorLib.ERROR_STRING_SELECTOR); // avoid incorrectly encoded Error(...)
        assertEq(WrappedErrorLib.unwrap(WrappedErrorLib.wrap(v)), v);
    }

    function test_idempotent_alreadyError() external pure {
        bytes memory err = abi.encodeWithSignature("Error(string)", "abc");
        assertEq(WrappedErrorLib.wrap(err), err, "f(x)");
        assertEq(WrappedErrorLib.wrap(WrappedErrorLib.wrap(err)), err, "f(f(x))");
        assertEq(WrappedErrorLib.unwrap(err), WrappedErrorLib.unwrap(WrappedErrorLib.unwrap(err)));
    }

    function test_idempotent_typedError() external pure {
        bytes memory err = abi.encodeWithSelector(TypedError.selector, 123, "abc");
        assertEq(WrappedErrorLib.wrap(WrappedErrorLib.wrap(err)), WrappedErrorLib.wrap(err));
        assertEq(
            WrappedErrorLib.unwrap(WrappedErrorLib.wrap(err)),
            WrappedErrorLib.unwrap(WrappedErrorLib.unwrap(err))
        );
    }

    function test_wrapAndRevert_alreadyError() external {
        bytes memory err = abi.encodeWithSignature("Error(string)", "abc");
        try this.wrapAndRevert(err) {} catch (bytes memory v) {
            assertEq(WrappedErrorLib.unwrap(v), err);
        }
        vm.expectRevert(err);
        this.wrapAndRevert(err);
    }

    function test_wrapAndRevert_typedError() external {
        bytes memory err = abi.encodeWithSelector(TypedError.selector, 123, "abc");
        try this.wrapAndRevert(err) {} catch (bytes memory v) {
            assertEq(WrappedErrorLib.unwrap(v), err);
        }
        vm.expectRevert(WrappedErrorLib.wrap(err));
        this.wrapAndRevert(err);
    }
}
