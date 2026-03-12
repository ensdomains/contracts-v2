// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {LibLabel} from "../utils/LibLabel.sol";

/// @title BatchRegistrar
/// @notice Simple batch registration contract for pre-migration of ENS names.
///         Only the owner can invoke batch registration.
contract BatchRegistrar is Ownable {
    IPermissionedRegistry public immutable ETH_REGISTRY;

    constructor(IPermissionedRegistry ethRegistry_, address owner_) Ownable(owner_) {
        ETH_REGISTRY = ethRegistry_;
    }

    /// @notice Batch register or renew names that share the same owner, registry, resolver, and role bitmap
    /// @param owner The owner for all names
    /// @param registry The registry for all names
    /// @param resolver The resolver for all names
    /// @param roleBitmap The role bitmap for all names
    /// @param labels Array of labels to register or renew
    /// @param expires Array of expiry timestamps corresponding to each label
    function batchRegister(
        address owner,
        IRegistry registry,
        address resolver,
        uint256 roleBitmap,
        string[] calldata labels,
        uint64[] calldata expires
    ) external onlyOwner {
        require(labels.length == expires.length);

        for (uint256 i = 0; i < labels.length; i++) {
            IPermissionedRegistry.State memory state = ETH_REGISTRY.getState(
                LibLabel.id(labels[i])
            );

            if (state.expiry > block.timestamp && state.latestOwner != address(0)) {
                continue;
            }

            if (state.expiry <= block.timestamp) {
                ETH_REGISTRY.register(labels[i], owner, registry, resolver, roleBitmap, expires[i]);
            } else {
                if (expires[i] > state.expiry) {
                    ETH_REGISTRY.renew(state.tokenId, expires[i]);
                }
            }
        }
    }
}
