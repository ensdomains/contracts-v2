// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper, CANNOT_UNWRAP} from "@ens/contracts/wrapper/INameWrapper.sol";

import {AbstractWrapperReceiver} from "./AbstractWrapperReceiver.sol";
import {LibMigration} from "./libraries/LibMigration.sol";

/// @notice Migration helper for mixed (ERC-721 and ERC-1155) batch migration using approval.
contract MigrationHelper {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 `UnlockedMigrationController`.
    AbstractWrapperReceiver public immutable UNLOCKED_CONTROLLER;

    /// @notice The ENSv2 `LockedMigrationController`.
    AbstractWrapperReceiver public immutable LOCKED_CONTROLLER;

    /// @notice The ENSv1 `NameWrapper` contract.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _REGISTRAR_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes `MigrationHelper`.
    /// @param unlockedController The ENSv2 `UnlockedMigrationController`.
    /// @param lockedController The ENSv2 `LockedMigrationController`.
    constructor(
        AbstractWrapperReceiver unlockedController,
        AbstractWrapperReceiver lockedController
    ) {
        UNLOCKED_CONTROLLER = unlockedController;
        LOCKED_CONTROLLER = lockedController;

        NAME_WRAPPER = unlocked.NAME_WRAPPER();
        _REGISTRAR_V1 = nameWrapper.registrar();
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Batch migration helper.
    /// @param mds Array of `LibMigration.Data`.
    function migrate(LibMigration.Data[] calldata mds) external {
        for (uint256 i; i < mds.length; ++i) {
            LibMigration.Data memory md = mds[i];
            uint256 tokenId = LibLabel.id(md.label);
            address owner = _REGISTRAR_V1.ownerOf(tokenId);
            bool locked;
            if (owner == address(NAME_WRAPPER)) {
                bytes32 node = NameCoder.namehash(NameCoder.ETH_NODE, bytes32(tokenId));
                uint32 fuses;
                (owner, fuses, ) = NAME_WRAPPER.getData(uint256(node));
                bool locked = (fuses & CANNOT_UNWRAP) != 0;
                NAME_WRAPPER.safeTransferFrom(
                    owner,
                    locked ? LOCKED_CONTROLLER : UNLOCKED_CONTROLLER,
                    uint256(node),
                    1,
                    abi.encode(md)
                );
            } else {
                _REGISTRAR_V1.safeTransferFrom(owner, UNLOCKED_CONTROLLER, tokenId, abi.encode(md));
            }
        }
    }
}
