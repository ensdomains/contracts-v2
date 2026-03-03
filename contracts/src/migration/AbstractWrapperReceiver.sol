// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {INameWrapper, CANNOT_UNWRAP} from "@ens/contracts/wrapper/INameWrapper.sol";
import {IERC1155Receiver} from "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {ERC165, IERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";
import {WrappedErrorLib} from "../utils/WrappedErrorLib.sol";

import {LibMigration} from "./libraries/LibMigration.sol";

abstract contract AbstractWrapperReceiver is ERC165, IERC1155Receiver {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    INameWrapper public immutable NAME_WRAPPER;

    ////////////////////////////////////////////////////////////////////////
    // Modifiers
    ////////////////////////////////////////////////////////////////////////

    /// @dev Restrict `msg.sender` to `NAME_WRAPPER`.
    ///      Reverts wrapped errors for use inside of legacy IERC1155Receiver handler.
    modifier onlyWrapper() {
        if (msg.sender != address(NAME_WRAPPER)) {
            WrappedErrorLib.wrapAndRevert(
                abi.encodeWithSelector(UnauthorizedCaller.selector, msg.sender)
            );
        }
        _;
    }

    /// @dev Avoid `abi.decode()` failure for obviously invalid data.
    ///      Reverts wrapped errors for use inside of legacy IERC1155Receiver handler.
    modifier withData(bytes calldata data, uint256 minimumSize) {
        if (data.length < minimumSize) {
            WrappedErrorLib.wrapAndRevert(
                abi.encodeWithSelector(LibMigration.InvalidData.selector)
            );
        }
        _;
    }

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    constructor(INameWrapper nameWrapper) {
        NAME_WRAPPER = nameWrapper;
    }

    /// @inheritdoc IERC165
    function supportsInterface(
        bytes4 interfaceId
    ) public view virtual override(ERC165, IERC165) returns (bool) {
        return
            interfaceId == type(IERC1155Receiver).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Returns `true` if the NameWrapper token is locked.
    function _isLocked(uint32 fuses) internal pure returns (bool) {
        // PARENT_CANNOT_CONTROL is required to set CANNOT_UNWRAP, so CANNOT_UNWRAP is sufficient
        // see: V1Fixture.t.sol: `test_nameWrapper_CANNOT_UNWRAP_requires_PARENT_CANNOT_CONTROL()`
        return (fuses & CANNOT_UNWRAP) != 0;
    }
}
