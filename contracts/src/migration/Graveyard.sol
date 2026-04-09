// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {ENS} from "@ens/contracts/registry/ENS.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {UnauthorizedCaller} from "../CommonErrors.sol";

/// @notice The ENSv1 ETHRegistrarController for ENSv2 launch which becomes the burn address for migrated ERC-721 tokens.
///
/// 1. Claim any expired ENSv1 name and assign ownership to this contract.
/// 2. Clear the registry for any owned token.
///
contract Graveyard is IERC721Receiver {
    /// @dev The ENSv1 `ENSRegistry` contract.
    ENS internal immutable _REGISTRY_V1;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _REGISTRAR_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Create a graveyard.
    /// @param ens The ENSv1 `ENSRegistry` contract.
    constructor(ENS ens) {
        _REGISTRY_V1 = ens;
        _REGISTRAR_V1 = IBaseRegistrar(ens.owner(NameCoder.ETH_NODE));
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Clear registry resolvers with automatic temporary registration.
    /// @param parentNodes The array of parent nodes.
    /// @param labelHashes The array of child labelhashes.
    function clear(bytes32[] calldata parentNodes, bytes32[] calldata labelHashes) external {
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

    /// @inheritdoc IERC721Receiver
    /// @notice Accept any ENSv1 `BaseRegistrar` token.
    function onERC721Received(
        address /*operator*/,
        address /*from*/,
        uint256 /*tokenId*/,
        bytes calldata /*data*/
    ) external view returns (bytes4) {
        if (msg.sender != address(_REGISTRAR_V1)) {
            revert UnauthorizedCaller(msg.sender);
        }
        return this.onERC721Received.selector;
    }
}
