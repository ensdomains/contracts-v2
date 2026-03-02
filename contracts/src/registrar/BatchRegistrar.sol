// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {LibLabel} from "../utils/LibLabel.sol";

struct BatchRegistrarName {
    string label;
    address owner;
    IRegistry registry;
    address resolver;
    uint256 roleBitmap;
    uint64 expires;
}

/// @title BatchRegistrar
/// @notice Simple batch registration contract for pre-migration of ENS names
contract BatchRegistrar {
    IPermissionedRegistry public immutable ETH_REGISTRY;

    constructor(IPermissionedRegistry ethRegistry_) {
        ETH_REGISTRY = ethRegistry_;
    }

    /// @notice Batch register or renew names
    /// @param names Array of names to register or renew
    /// @dev For each name:
    ///      - If not registered or expired: register it
    ///      - If registered with different expiry: renew to sync expiry with v1
    ///      - If registered with same expiry: skip (no-op)
    function batchRegister(BatchRegistrarName[] calldata names) external {
        for (uint256 i = 0; i < names.length; i++) {
            BatchRegistrarName calldata name = names[i];

            IPermissionedRegistry.State memory state = ETH_REGISTRY.getState(
                LibLabel.id(name.label)
            );

            if (state.expiry == 0 || state.expiry <= block.timestamp) {
                ETH_REGISTRY.register(
                    name.label,
                    name.owner,
                    name.registry,
                    name.resolver,
                    name.roleBitmap,
                    name.expires
                );
            } else {
                if (name.expires > state.expiry) {
                    ETH_REGISTRY.renew(state.tokenId, name.expires);
                }
            }
        }
    }
}
