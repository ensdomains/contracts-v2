// SPDX-License-Identifier: MIT
pragma solidity 0.8.25;

import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

import {ILabelStore} from "../utils/interfaces/ILabelStore.sol";

import {IRegistryURIRenderer} from "./interfaces/IRegistryURIRenderer.sol";
import {RegistryRolesLib} from "./libraries/RegistryRolesLib.sol";
import {UserRegistryWithUpgradeSet} from "./UserRegistryWithUpgradeSet.sol";

/// @notice UserRegistry for fixing previous implementations with a trusted authority.
contract UserRegistryWithUpgradeBlackout is UserRegistryWithUpgradeSet {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @dev Signer for upgrades during blackout.
    address internal immutable _BLACKOUT_UPGRADE_SIGNER;

    /// @dev Blackout upgrade implementation. 
    UserRegistryWithUpgradeSet internal immutable _BLACKOUT_IMPLEMENTATION;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice First block of the blackout (inclusive).
    uint64 public upgradeBlackoutFirstBlock;

    /// @notice Last block of the blackout (inclusive). 
    uint64 public upgradeBlackoutLastBlock;

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice Normal upgrades are blocked during blackout.
    /// @dev Error selector: `0xfb7cfb8f`
    error UpgradeDuringBlackout();

    /// @notice Upgrade can only occur while normal upgrades are disabled.
    /// @dev Error selector: `0x9348a56f`
    error UpgradeRequiresBlackout();

    /// @notice Signature did not authorize the upgrade.
    /// @dev Error selector: `0xc8ab00cf`
    error UpgradeNotAuthorized();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @param labelStore The shared label database.
    /// @param uriRenderer The default URI renderer.
    /// @param namer The implementation namer.
    /// @param implementations List of supported implementations.
    /// @param blackoutUpgradeSigner Signer for upgrades during blackout.
    constructor(
        ILabelStore labelStore,
        IRegistryURIRenderer uriRenderer,
        address namer,
        address[] memory implementations,
        address blackoutUpgradeSigner
    )
        UserRegistryWithUpgradeSet(labelStore, uriRenderer, namer, implementations)
    {
        _BLACKOUT_UPGRADE_SIGNER = blackoutUpgradeSigner;

        address[] memory impls = new address[](1);
        impls[0] = address(this);
        _BLACKOUT_IMPLEMENTATION = new UserRegistryWithUpgradeSet(
            labelStore,
            uriRenderer,
            namer,
            impls
        );
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Reinitialize the contract.
    /// @param blocks Number of blocks upgrades are disabled.
    function reinitWithUpgradeBlackout(uint256 blocks) external reinitializer(2) {
        upgradeBlackoutFirstBlock = uint64(block.number);
        upgradeBlackoutLastBlock = uint64(block.number + blocks);
    }

    /// @notice Refresh upgrade blackout.
    /// @param blocks Number of blocks upgrades are disabled.
    function refreshUpgradeBlackout(uint256 blocks)
        external
        onlyRootRoles(RegistryRolesLib.ROLE_UPGRADE)
    {
        uint64 until = uint64(block.number + blocks);
        if (_blackoutIncludes(block.number)) {
            if (upgradeBlackoutLastBlock < until) {
                upgradeBlackoutLastBlock = until; // extend
            }
        } else {
            upgradeBlackoutFirstBlock = uint64(block.number);
            upgradeBlackoutLastBlock = until; // replace
        }
    }

    /// @notice Return `true` if during upgrade blackout.
    function isDuringUpgradeBlackout() external view returns (bool) {
        return _blackoutIncludes(block.number);
    }

    /// @inheritdoc UUPSUpgradeable
    /// @dev Override: validate blackout upgrades.
    function upgradeToAndCall(address newImplementation, bytes memory data) public payable override {
        if (newImplementation == address(_BLACKOUT_IMPLEMENTATION)) {
            (uint256 blockNumber, bytes memory signature) = abi.decode(data, (uint256, bytes));
            if (!_blackoutIncludes(block.number)) {
                revert UpgradeRequiresBlackout();
            }
            if (
                blockNumber != upgradeBlackoutFirstBlock ||
                !SignatureChecker.isValidSignatureNow(
                    _BLACKOUT_UPGRADE_SIGNER,
                    keccak256(abi.encode(address(this), newImplementation, blockNumber)),
                    signature
                )
            ) {
                revert UpgradeNotAuthorized();
            }
            delete upgradeBlackoutFirstBlock; // mark for upgrade during blackout, see: _authorizeUpgrade()
            delete data;
        }
        super.upgradeToAndCall(newImplementation, data);
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Override: allow normal upgrades but block upgrade to the blackout implementation.
    ///      During blackout, only allow an authorized upgrade to the blackout implementation.
    function _authorizeUpgrade(address newImplementation) internal override {
        if (_blackoutIncludes(block.number)) {
            if (upgradeBlackoutFirstBlock == 0) {
                // the only way the first block can be zero and inside the interval 
                // is to be a continuation of the authorized upgradeToAndCall flow
                delete upgradeBlackoutLastBlock;
            } else {
                revert UpgradeDuringBlackout();
            }
        } else if (newImplementation == address(_BLACKOUT_IMPLEMENTATION)) {
            revert UpgradeRequiresBlackout();
        }
        super._authorizeUpgrade(newImplementation);
    }

    /// @dev Return `true` if blackout contains `blockNumber` (inclusive).
    function _blackoutIncludes(uint256 blockNumber) internal view returns (bool) {
        return blockNumber >= upgradeBlackoutFirstBlock && blockNumber <= upgradeBlackoutLastBlock;
    }
}
