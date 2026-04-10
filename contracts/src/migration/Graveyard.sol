// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {ENS} from "@ens/contracts/registry/ENS.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

/// @notice The ENSv1 ETHRegistrarController for ENSv2 launch which becomes the burn address for migrated tokens.
///
/// 1. Claim any expired ENSv1 name and assign ownership to this contract.
/// 2. Clear the registry for any owned token.
///
contract Graveyard is ERC721Holder, ERC1155Holder {
    /// @notice The ENSv1 `NameWrapper` contract.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev The ENSv1 `ENSRegistry` contract.
    ENS internal immutable _REGISTRY_V1;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _REGISTRAR_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Create a graveyard.
    /// @param nameWrapper The ENSv1 `NameWrapper` contract.
    constructor(INameWrapper nameWrapper) {
        NAME_WRAPPER = nameWrapper;
        _REGISTRY_V1 = nameWrapper.ens();
        _REGISTRAR_V1 = nameWrapper.registrar();
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Clear registry for unwrapped names with automatic temporary registration.
    /// @param parentNodes The array of unwrapped parent nodes.
    /// @param labelHashes The array of child labelhashes.
    function clearUnwrapped(
        bytes32[] calldata parentNodes,
        bytes32[] calldata labelHashes
    ) external {
        for (uint256 i; i < parentNodes.length; ++i) {
            bytes32 parentNode = parentNodes[i];
            bytes32 labelHash = labelHashes[i];
            if (parentNode == NameCoder.ETH_NODE) {
                bytes32 node = NameCoder.namehash(parentNode, labelHash);
                if (_REGISTRY_V1.owner(node) != address(this)) {
                    _REGISTRAR_V1.register(uint256(labelHash), address(this), 1);
                }
                _REGISTRY_V1.setResolver(node, address(0));
            } else {
                _REGISTRY_V1.setSubnodeRecord(parentNode, labelHash, address(this), address(0), 0);
            }
        }
    }

    /// @notice Clear registry for wrapped children with automatic unwrap.
    /// @param parentNodes The array of wrapped parent nodes.
    /// @param labels The array of child labels.
    function clearWrappedChildren(
        bytes32[] calldata parentNodes,
        string[] calldata labels
    ) external {
        for (uint256 i; i < parentNodes.length; ++i) {
            bytes32 parentNode = parentNodes[i];
            string calldata label = labels[i];
            //bytes32 node = NAME_WRAPPER.setSubnodeRecord(
            NAME_WRAPPER.setSubnodeRecord(
                parentNode,
                label,
                address(this), // owner
                address(0), // resolver
                0, // ttl
                0, // fuses
                0 // expiry
            );
            //(, uint32 fuses, ) = NAME_WRAPPER.getData(uint256(node));
            //if (!LibMigration.isLocked(fuses)) {
            NAME_WRAPPER.unwrap(parentNode, keccak256(bytes(label)), address(this));
        }
    }
}
