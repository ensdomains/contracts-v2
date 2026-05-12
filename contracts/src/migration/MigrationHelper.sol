// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";

import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {LibRegistry} from "../universalResolver/libraries/LibRegistry.sol";

import {AbstractWrapperReceiver} from "./AbstractWrapperReceiver.sol";
import {LibMigration} from "./libraries/LibMigration.sol";

/// @dev Struct for migrating locked 3LD+ tokens.
struct LockedChildren {
    /// @param parentName The parent name.
    bytes parentName;
    /// @param groups Array of Groups of `LibMigration.Data` for locked tokens with a common owner.
    LibMigration.Data[][] groups;
}

/// @notice Migration helper for mixed (ERC-721 and ERC-1155) batch migration using approval.
contract MigrationHelper is HCAEquivalence {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 root registry.
    IRegistry public immutable ROOT_REGISTRY;

    /// @notice The ENSv2 `UnlockedMigrationController` contract.
    AbstractWrapperReceiver public immutable UNLOCKED_CONTROLLER;

    /// @notice The ENSv2 `LockedMigrationController` contract.
    AbstractWrapperReceiver public immutable LOCKED_CONTROLLER;

    /// @notice The ENSv1 `NameWrapper` contract.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _REGISTRAR_V1;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice A group has multiple owners.
    /// @dev Error selector: `0xd04374c0`
    error WrappedOwnerMismatch(uint256 tokenId);

    /// @notice A parent has not been migrated yet.
    /// @dev Error selector: `0x83d435f1`
    error ParentNotMigrated(bytes name);

    /// @notice Caller is not an approved operator by `owner` on `nft`.
    /// @dev Error selector: `0x1cf8fdfe`
    error NotApprovedOperator(address nft, address owner);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes `MigrationHelper`.
    /// @param hcaFactory The HCA factory to use.
    /// @param rootRegistry The root registry.
    /// @param unlockedController The ENSv2 `UnlockedMigrationController`.
    /// @param lockedController The ENSv2 `LockedMigrationController`.
    constructor(
        IHCAFactoryBasic hcaFactory,
        IRegistry rootRegistry,
        AbstractWrapperReceiver unlockedController,
        AbstractWrapperReceiver lockedController
    )
        HCAEquivalence(hcaFactory)
    {
        ROOT_REGISTRY = rootRegistry;
        UNLOCKED_CONTROLLER = unlockedController;
        LOCKED_CONTROLLER = lockedController;

        NAME_WRAPPER = unlockedController.NAME_WRAPPER();
        _REGISTRAR_V1 = NAME_WRAPPER.registrar();
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Optimized batch migration helper.
    /// @param unwrapped Array of `LibMigration.Data` for unwrapped tokens.
    /// @param unlockedGroups Array of Groups of `LibMigration.Data` for unlocked 2LD tokens with a common owner.
    /// @param lockedGroups Array of Groups of `LibMigration.Data` for locked 2LD tokens with a common owner.
    /// @param lockedChildrenGroups Array of `LockedChildren` for 3LD+ tokens.
    function migrate(
        LibMigration.Data[] calldata unwrapped,
        LibMigration.Data[][] calldata unlockedGroups,
        LibMigration.Data[][] calldata lockedGroups,
        LockedChildren[] calldata lockedChildrenGroups
    )
        external
    {
        address sender = _msgSenderWithHcaEquivalence();
        for (uint256 i; i < unwrapped.length; ++i) {
            LibMigration.Data calldata md = unwrapped[i];
            uint256 tokenId = uint256(keccak256(bytes(md.label)));
            address owner = _REGISTRAR_V1.ownerOf(tokenId);
            _requireOperatorApproval(address(_REGISTRAR_V1), owner, sender);
            _REGISTRAR_V1.safeTransferFrom(
                owner,
                address(UNLOCKED_CONTROLLER),
                tokenId,
                abi.encode(md)
            );
        }
        for (uint256 i; i < unlockedGroups.length; ++i) {
            _transferWrapped(
                sender,
                NameCoder.ETH_NODE,
                address(UNLOCKED_CONTROLLER),
                unlockedGroups[i]
            );
        }
        for (uint256 i; i < lockedGroups.length; ++i) {
            _transferWrapped(sender, NameCoder.ETH_NODE, address(LOCKED_CONTROLLER), lockedGroups[i]);
        }
        for (uint256 j; j < lockedChildrenGroups.length; ++j) {
            LockedChildren calldata lc = lockedChildrenGroups[j];
            IRegistry registry = LibRegistry.findExactRegistry(ROOT_REGISTRY, lc.parentName, 0);
            if (address(registry) == address(0)) {
                revert ParentNotMigrated(lc.parentName);
            }
            for (uint256 i; i < lc.groups.length; ++i) {
                _transferWrapped(
                    sender,
                    NameCoder.namehash(lc.parentName, 0),
                    address(registry),
                    lc.groups[i]
                );
            }
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Batch transfer NameWrapper tokens.
    function _transferWrapped(
        address sender,
        bytes32 parentNode,
        address receiver,
        LibMigration.Data[] memory mds
    )
        internal
    {
        uint256 n = mds.length;
        if (n == 0) {
            return;
        }
        address from;
        uint256[] memory ids = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            LibMigration.Data memory md = mds[i];
            uint256 id = uint256(NameCoder.namehash(parentNode, keccak256(bytes(md.label))));
            (address owner, , ) = NAME_WRAPPER.getData(id);
            _requireOperatorApproval(address(NAME_WRAPPER), owner, sender);
            if (i == 0) {
                from = owner;
            } else if (from != owner) {
                revert WrappedOwnerMismatch(id);
            }
            ids[i] = id;
        }
        if (n == 1) {
            NAME_WRAPPER.safeTransferFrom(from, receiver, ids[0], 1, abi.encode(mds[0]));
        } else {
            uint256[] memory amounts = new uint256[](n);
            for (uint256 i; i < n; ++i) {
                amounts[i] = 1;
            }
            NAME_WRAPPER.safeBatchTransferFrom(from, receiver, ids, amounts, abi.encode(mds));
        }
    }

    /// @dev Ensure operator is owner or approved by owner.
    function _requireOperatorApproval(address nft, address owner, address operator) internal view {
        // transfer() will check if from is approved by this contract
        // note: both IBaseRegistrar and INameWrapper implement isApprovedForAll()
        if (owner != operator && !INameWrapper(nft).isApprovedForAll(owner, operator)) {
            revert NotApprovedOperator(nft, owner);
        }
    }
}
