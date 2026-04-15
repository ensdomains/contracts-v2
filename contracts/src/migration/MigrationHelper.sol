// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper, CANNOT_UNWRAP} from "@ens/contracts/wrapper/INameWrapper.sol";

import {InvalidOwner} from "../CommonErrors.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {AbstractWrapperReceiver} from "./AbstractWrapperReceiver.sol";
import {LibMigration} from "./libraries/LibMigration.sol";

/// @notice Migration helper for mixed (ERC-721 and ERC-1155) batch migration using approval.
contract MigrationHelper is HCAEquivalence {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv2 `UnlockedMigrationController` contract.
    AbstractWrapperReceiver public immutable UNLOCKED_CONTROLLER;

    /// @notice The ENSv2 `LockedMigrationController` contract.
    AbstractWrapperReceiver public immutable LOCKED_CONTROLLER;

    /// @notice The ENSv1 `NameWrapper` contract.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _REGISTRAR_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes `MigrationHelper`.
    /// @param hcaFactory The HCA factory to use.
    /// @param unlockedController The ENSv2 `UnlockedMigrationController`.
    /// @param lockedController The ENSv2 `LockedMigrationController`.
    constructor(
        IHCAFactoryBasic hcaFactory,
        AbstractWrapperReceiver unlockedController,
        AbstractWrapperReceiver lockedController
    ) HCAEquivalence(hcaFactory) {
        UNLOCKED_CONTROLLER = unlockedController;
        LOCKED_CONTROLLER = lockedController;

        NAME_WRAPPER = unlockedController.NAME_WRAPPER();
        _REGISTRAR_V1 = NAME_WRAPPER.registrar();
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Optimized batch migration helper that assumes every token is owned by sender.
    /// @param unwrapped Array of `LibMigration.Data` for unwrapped tokens.
    /// @param unlocked Array of `LibMigration.Data` for unlocked tokens.
    /// @param locked Array of `LibMigration.Data` for locked tokens.
    function migrate(
        LibMigration.Data[] calldata unwrapped,
        LibMigration.Data[] calldata unlocked,
        LibMigration.Data[] calldata locked
    ) external {
        address sender = _msgSenderWithHcaEquivalence();
        for (uint256 i; i < unwrapped.length; ++i) {
            LibMigration.Data calldata md = unwrapped[i];
            uint256 tokenId = LibLabel.id(md.label);
            address owner = _REGISTRAR_V1.ownerOf(tokenId);
            _checkOperatorApproval(address(_REGISTRAR_V1), owner, sender);
            _REGISTRAR_V1.safeTransferFrom(
                owner,
                address(UNLOCKED_CONTROLLER),
                tokenId,
                abi.encode(md)
            );
        }
        if (unlocked.length > 0) {
            _transferWrapped(sender, address(UNLOCKED_CONTROLLER), unlocked);
        }
        if (locked.length > 0) {
            _transferWrapped(sender, address(LOCKED_CONTROLLER), locked);
        }
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Batch transfer NameWrapper tokens for a single owner.
    function _transferWrapped(
        address operator,
        address to,
        LibMigration.Data[] memory mds
    ) internal {
        uint256 n = mds.length;
        uint256[] memory ids = new uint256[](n);
        address[] memory froms = new address[](n);
        uint256[] memory amounts = new uint256[](n);
        for (uint256 i; i < n; ++i) {
            LibMigration.Data memory md = mds[i];
            uint256 id = uint256(
                NameCoder.namehash(NameCoder.ETH_NODE, bytes32(LibLabel.id(md.label)))
            );
            (address owner, , ) = NAME_WRAPPER.getData(id);
            _checkOperatorApproval(address(NAME_WRAPPER), owner, operator);
            froms[i] = owner;
            ids[i] = id;
            amounts[i] = 1;
        }
        _sortByFrom(froms, ids, mds);
        while (n > 0) {
            address from = froms[0];
            uint256 count = 1;
            while (count < n && froms[count] == from) {
                ++count;
            }
            if (count == 1) {
                NAME_WRAPPER.safeTransferFrom(from, to, ids[0], 1, abi.encode(mds[0]));
            } else {
                assembly {
                    // temporary truncate
                    mstore(ids, count)
                    mstore(mds, count)
                    mstore(amounts, count)
                }
                NAME_WRAPPER.safeBatchTransferFrom(from, to, ids, amounts, abi.encode(mds));
            }
            assembly {
                // shift array start
                let shift := shl(5, count)
                froms := add(froms, shift)
                ids := add(ids, shift)
                mds := add(mds, shift)
                // reduce capacity
                n := sub(n, count)
                mstore(ids, n)
                mstore(mds, n)
            }
        }
    }

    /// @dev Check if operator is owner or approved by owner.
    function _checkOperatorApproval(address nft, address owner, address operator) internal view {
        if (operator != owner) {
            // transfer() will check if from is approved by this contract
            // both IBaseRegistrar and INameWrapper implement isApprovedForAll()
            if (!INameWrapper(nft).isApprovedForAll(owner, operator)) {
                revert InvalidOwner();
            }
        }
    }

    /// @dev Sort multiple arrays by `from`.
    function _sortByFrom(
        address[] memory froms,
        uint256[] memory ids,
        LibMigration.Data[] memory mds
    ) internal pure {
        uint256 n = froms.length;

        for (uint256 i = 1; i < n; ++i) {
            address from = froms[i];
            uint256 id = ids[i];
            LibMigration.Data memory md = mds[i];

            uint256 j = i;
            while (j > 0 && froms[j - 1] > from) {
                froms[j] = froms[j - 1];
                ids[j] = ids[j - 1];
                mds[j] = mds[j - 1];
                --j;
            }

            froms[j] = from;
            ids[j] = id;
            mds[j] = md;
        }
    }
}
