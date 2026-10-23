// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IVerifiableFactory} from "@ensdomains/verifiable-factory/IVerifiableFactory.sol";

/// @dev Helper functions related to `WrapperRegistry`.
library WrapperRegistryLib {
    /// @notice Name did not match `*.eth`.
    /// @dev Error selector: `0xe6277bc6`
    error NotETHDescendant();

    /// @dev Compute `WrapperRegistry` address for a `name`.
    /// @param verifiableFactory The `VerifiableFactory`.
    /// @param lockedMigrationController The `LockedMigrationController`.
    /// @param name The DNS-encoded name.
    /// @return addr The address of the `WrapperRegistry` corresponding to `name`.
    function computeAddress(
        IVerifiableFactory verifiableFactory,
        address lockedMigrationController,
        bytes memory name
    )
        internal
        view
        returns (address addr)
    {
        (, addr) = _computeAddress(verifiableFactory, lockedMigrationController, name, 0);
        if (addr == address(0)) {
            revert NotETHDescendant();
        }
    }

    /// @dev Recursive function for computing the registry address.
    function _computeAddress(
        IVerifiableFactory verifiableFactory,
        address lockedMigrationController,
        bytes memory name,
        uint256 offset
    )
        internal
        view
        returns (bytes32 node, address addr)
    {
        (bytes32 labelHash, uint256 next) = NameCoder.readLabel(name, offset);
        if (labelHash != bytes32(0)) {
            (node, addr) = _computeAddress(verifiableFactory, lockedMigrationController, name, next);
            if (node == NameCoder.ETH_NODE) {
                addr = lockedMigrationController;
            }
            node = NameCoder.namehash(node, labelHash);
            if (addr != address(0)) {
                addr = verifiableFactory.predictProxyAddress(addr, uint256(node));
            }
        }
    }
}
