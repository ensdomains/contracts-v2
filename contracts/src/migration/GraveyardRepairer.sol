// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {
    BaseRegistrarImplementation
} from "@ens/contracts/ethregistrar/BaseRegistrarImplementation.sol";
import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {ENS} from "@ens/contracts/registry/ENS.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";

import {Graveyard} from "./Graveyard.sol";

/// @notice Repairs .eth names that were handed to a `Graveyard` with a resolver set.
///
/// A migration hands a node to the `Graveyard` with its resolver cleared. The `Graveyard` deployed
/// on mainnet trusts that and never writes a .eth node it already owns, and it cannot be upgraded.
/// Any registry owner can hand a node over with a resolver of their choice, which then outlives
/// the registration.
///
/// Once such a registration lapses, this contract registers the name to itself, clears the
/// resolver, and hands the node and the token to the `Graveyard`. The name is then left as
/// `Graveyard.clear()` leaves any expired name, and the `Graveyard` clears its subnames as usual.
///
/// Requires the `BaseRegistrar` controller role.
///
contract GraveyardRepairer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The `Graveyard` that holds repaired names.
    address public immutable GRAVEYARD;

    /// @dev The ENSv1 `ENSRegistry` contract.
    ENS internal immutable _REGISTRY_V1;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _BASE_REGISTRAR;

    /// @dev Same as `BaseRegistrarImplementation.GRACE_PERIOD()`.
    uint256 internal immutable _GRACE_PERIOD;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice A name was cleared and handed to the `Graveyard`.
    /// @param tokenId The `BaseRegistrar` token ID (labelhash) of the name.
    event Repaired(uint256 indexed tokenId);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Create a repairer for a graveyard.
    /// @param graveyard The `Graveyard` that holds repaired names.
    constructor(Graveyard graveyard) {
        GRAVEYARD = address(graveyard);
        _REGISTRY_V1 = graveyard.NAME_WRAPPER().ens();
        _BASE_REGISTRAR = graveyard.NAME_WRAPPER().registrar();
        _GRACE_PERIOD = BaseRegistrarImplementation(address(_BASE_REGISTRAR)).GRACE_PERIOD();
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Repair every repairable name and skip the rest.
    /// @param tokenIds The `BaseRegistrar` token IDs (labelhashes) of the names.
    /// @return repaired The number of names repaired.
    function repair(uint256[] calldata tokenIds) external returns (uint256 repaired) {
        for (uint256 i; i < tokenIds.length; ++i) {
            uint256 tokenId = tokenIds[i];
            if (!isRepairable(tokenId)) {
                continue;
            }
            bytes32 node = NameCoder.namehash(NameCoder.ETH_NODE, bytes32(tokenId));
            _BASE_REGISTRAR.register(
                tokenId,
                address(this),
                type(uint64).max - block.timestamp - _GRACE_PERIOD // same as `Graveyard`
            );
            _REGISTRY_V1.setResolver(node, address(0));
            _REGISTRY_V1.setOwner(node, GRAVEYARD);
            // ERC721 transfers return nothing
            // solgrid-disable-next-line security/unchecked-transfer
            _BASE_REGISTRAR.transferFrom(address(this), GRAVEYARD, tokenId);
            emit Repaired(tokenId);
            ++repaired;
        }
    }

    /// @notice Determine if a name is held by the `Graveyard` with a resolver set and its
    ///         registration has lapsed past the grace period.
    /// @dev A name that was never registered is skipped, as `Graveyard.clear()` refuses it.
    /// @param tokenId The `BaseRegistrar` token ID (labelhash) of the name.
    /// @return True if `repair()` would repair the name.
    function isRepairable(uint256 tokenId) public view returns (bool) {
        bytes32 node = NameCoder.namehash(NameCoder.ETH_NODE, bytes32(tokenId));
        return
            _REGISTRY_V1.owner(node) == GRAVEYARD &&
            _REGISTRY_V1.resolver(node) != address(0) &&
            _BASE_REGISTRAR.nameExpires(tokenId) != 0 &&
            _BASE_REGISTRAR.available(tokenId);
    }
}
