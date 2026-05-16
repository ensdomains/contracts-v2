// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    BaseRegistrarImplementation
} from "@ens/contracts/ethregistrar/BaseRegistrarImplementation.sol";
import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {ENS} from "@ens/contracts/registry/ENS.sol";
import {HexUtils} from "@ens/contracts/utils/HexUtils.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {ERC1155Holder} from "@openzeppelin/contracts/token/ERC1155/utils/ERC1155Holder.sol";
import {ERC721Holder} from "@openzeppelin/contracts/token/ERC721/utils/ERC721Holder.sol";

import {LibMigration} from "./libraries/LibMigration.sol";

/// @notice The ENSv1 ETHRegistrarController for ENSv2 launch which becomes the burn address for migrated tokens.
///
/// 1. Claim any expired ENSv1 name and assign ownership to this contract.
/// 2. Clear the registry for any owned token.
///
contract Graveyard is ERC721Holder, ERC1155Holder {
    ////////////////////////////////////////////////////////////////////////
    // Types
    ////////////////////////////////////////////////////////////////////////

    /// @dev The internal states of registry ownership.
    enum State {
        ROOT,
        ETH,
        OWNED,
        LOCKED
    }

    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv1 `NameWrapper` contract.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev The ENSv1 `ENSRegistry` contract.
    ENS internal immutable _REGISTRY_V1;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _BASE_REGISTRAR;

    /// @dev Same as `BaseRegistrarImplementation.GRACE_PERIOD()`.
    uint256 internal immutable _GRACE_PERIOD;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @dev Error selector: `0xacae6b3b`
    error NameNotClearable();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Create a graveyard.
    /// @param nameWrapper The ENSv1 `NameWrapper` contract.
    constructor(INameWrapper nameWrapper) {
        NAME_WRAPPER = nameWrapper;
        _REGISTRY_V1 = nameWrapper.ens();
        _BASE_REGISTRAR = nameWrapper.registrar();
        _GRACE_PERIOD = BaseRegistrarImplementation(address(_BASE_REGISTRAR)).GRACE_PERIOD();
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Clear registry for migrated names.
    /// @dev Append non-zero byte to process encoded-labels.
    /// @param names The array of names to clear.
    function clear(bytes[] calldata names) external {
        for (uint256 i; i < names.length; ++i) {
            bytes calldata name = names[i];
            bool encoded = name.length > 0 && uint8(name[name.length - 1]) > 0;
            if (encoded) {
                name = name[:name.length - 1]; // remove tail byte
            }
            _clear(name, 0, encoded);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Recursively clear ancestor namespace.
    function _clear(bytes calldata name, uint256 offset, bool encoded)
        internal
        returns (bytes32 node, State state)
    {
        (uint8 size, uint256 nextOffset) = NameCoder.nextLabel(name, offset);
        if (size == 0) {
            return (bytes32(0), State.ROOT);
        }
        bytes32 parentNode;
        (parentNode, state) = _clear(name, nextOffset, encoded);
        bytes32 labelHash;
        if (encoded && size == 66 && name[offset + 1] == "[" && name[nextOffset - 1] == "]") {
            (labelHash, encoded) = HexUtils.hexStringToBytes32(name[offset + 2:offset + 66], 0, 64);
        } else {
            encoded = false;
        }
        if (!encoded) {
            labelHash = keccak256(name[offset + 1:offset + 1 + size]);
        }
        node = NameCoder.namehash(parentNode, labelHash);
        if (state == State.ROOT) {
            if (node != NameCoder.ETH_NODE) {
                revert NameNotClearable();
            }
            return (node, State.ETH);
        } else if (state == State.ETH) {
            address owner = _REGISTRY_V1.owner(node);
            if (owner == address(this)) {
                // resolver is cleared by migration
                return (node, State.OWNED);
            }
            uint32 fuses;
            (owner, fuses, ) = NAME_WRAPPER.getData(uint256(node));
            if (LibMigration.isLocked(fuses)) {
                if (owner != address(this)) {
                    revert NameNotClearable();
                }
                // resolver is cleared by migration
                return (node, State.LOCKED);
            }
            _BASE_REGISTRAR.register(
                uint256(labelHash),
                address(this),
                type(uint64).max - block.timestamp - _GRACE_PERIOD // max duration?
            );
            // lock expired? so clear it
            if (_REGISTRY_V1.resolver(node) != address(0)) {
                _REGISTRY_V1.setResolver(node, address(0));
            }
            return (node, State.OWNED);
        } else if (state == State.OWNED) {
            _REGISTRY_V1.setSubnodeRecord(parentNode, labelHash, address(this), address(0), 0);
            return (node, State.OWNED);
        } else {
            (address owner, uint32 fuses, ) = NAME_WRAPPER.getData(uint256(node));
            if (owner == address(this)) {
                // resolver is cleared by migration
                if (LibMigration.isLocked(fuses)) {
                    return (node, State.LOCKED);
                }
                // } else if (LibMigration.isEmancipatedChild(fuses)) {
                //    return (node, State.OWNED);
                // }
            } else if (owner != address(0)) {
                NAME_WRAPPER.setSubnodeRecord(
                    parentNode,
                    string(name[offset + 1:nextOffset]),
                    address(this), // owner
                    address(0), // resolver
                    0, // ttl
                    0, // fuses
                    0 // expiry (uses min)
                ); // reverts if not migrated
                NAME_WRAPPER.unwrap(parentNode, labelHash, address(this));
            }
            return (node, State.OWNED);
        }
    }
}
