// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    BaseRegistrarImplementation
} from "@ens/contracts/ethregistrar/BaseRegistrarImplementation.sol";
import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {
    INameWrapper,
    CANNOT_TRANSFER,
    CANNOT_APPROVE
} from "@ens/contracts/wrapper/INameWrapper.sol";

import {LibMigration} from "../migration/libraries/LibMigration.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {LibLabel} from "../utils/LibLabel.sol";

/// @notice `ETHRegistrarController.renew()` stub interface.
/// @dev Interface selector: `0xacf1a841`
interface IWrappedETHRegistrarController {
    /// @notice Renew an ENSv1 name.
    /// @param label The name to renew.
    /// @param duration The expiry extension, in seconds.
    function renew(string calldata label, uint256 duration) external payable;
}

/// @notice A mechanism to sync ENSv2 registrations with ENSv1 after launch.
///
/// To sync:
/// 1. renew() in v2
/// 2. must be unmigratable or v1 expiry < CUTOFF_EXPIRY
///
/// To be unmigratable:
/// 1. must be Locked .eth 2LD (NameWrapper w/CANNOT_UNLOCK burned)
/// 2. must have at least one of:
///     - CANNOT_TRANSFER burned
///     - CANNOT_APPROVE burned w/non-null getApproved()
///
contract ETHRenewerV1 {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv1 `NameWrapper` contract that holds wrapped names as ERC1155 tokens.
    INameWrapper public immutable NAME_WRAPPER;

    /// @notice The ENSv1 `ETHRegistrarController` that is a `NameWrapper` controller.
    IWrappedETHRegistrarController public immutable WRAPPED_CONTROLLER;

    /// @notice The ENSv2 .eth `PermissionedRegistry` where migrated names are registered.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    /// @notice The maximum expiry this contract will renew for, in seconds.
    uint64 public immutable CUTOFF_EXPIRY;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _REGISTRAR_V1;

    /// @dev The ENSv1 `GRACE_PERIOD`, in seconds.
    uint64 internal immutable _GRACE_PERIOD;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes WrapperRenewerV1.
    /// @param nameWrapper The ENSv1 `NameWrapper` contract.
    /// @param wrappedController The ENSv1 `ETHRegistrarController` that is a `NameWrapper` controller.
    /// @param ethRegistry The ENSv2 .eth `PermissionedRegistry` where migrated names are registered.
    /// @param cutoffExpiry The maximum expiry this contract will renew for, in seconds.
    constructor(
        INameWrapper nameWrapper,
        address wrappedController,
        IPermissionedRegistry ethRegistry,
        uint64 cutoffExpiry
    ) {
        NAME_WRAPPER = nameWrapper;
        WRAPPED_CONTROLLER = IWrappedETHRegistrarController(wrappedController);
        ETH_REGISTRY = ethRegistry;
        CUTOFF_EXPIRY = cutoffExpiry;
        _REGISTRAR_V1 = nameWrapper.registrar();
        _GRACE_PERIOD = uint64(BaseRegistrarImplementation(address(_REGISTRAR_V1)).GRACE_PERIOD());
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Sync ENSv2 with ENSv1.
    /// @param labels The labels to sync.
    function sync(string[] calldata labels) external {
        bool added;
        for (uint256 i; i < labels.length; ++i) {
            string calldata label = labels[i];
            uint256 tokenIdV1 = LibLabel.id(label);
            (uint64 syncDuration, bool syncWrapper) = _getState(tokenIdV1);
            if (syncDuration > 0) {
                _REGISTRAR_V1.renew(tokenIdV1, syncDuration);
            }
            if (syncWrapper) {
                if (!added) {
                    added = true;
                    _REGISTRAR_V1.addController(address(WRAPPED_CONTROLLER));
                }
                WRAPPED_CONTROLLER.renew(label, 0);
            }
        }
        if (added) {
            _REGISTRAR_V1.removeController(address(WRAPPED_CONTROLLER));
        }
    }

    /// @notice Determine if name can be synced.
    /// @param label The name to sync.
    /// @return `true` if name can be synced.
    function canSync(string calldata label) external view returns (bool) {
        (uint64 syncDuration, bool syncWrapper) = _getState(LibLabel.id(label));
        return syncDuration > 0 || syncWrapper;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Determine necessary synchronization.
    function _getState(
        uint256 tokenIdV1
    ) internal view returns (uint64 syncDuration, bool syncWrapper) {
        IPermissionedRegistry.State memory state = ETH_REGISTRY.getState(tokenIdV1);
        if (state.status == IPermissionedRegistry.Status.RESERVED) {
            bytes32 node = NameCoder.namehash(NameCoder.ETH_NODE, bytes32(tokenIdV1));
            uint64 expiryV2 = state.expiry;
            uint64 expiryV1 = uint64(_REGISTRAR_V1.nameExpires(tokenIdV1));
            (address owner, uint32 fuses, uint64 wrappedExpiry) = NAME_WRAPPER.getData(
                uint256(node)
            );
            if (expiryV2 > CUTOFF_EXPIRY && _isMigratable(node, fuses)) {
                expiryV2 = CUTOFF_EXPIRY;
            }
            if (expiryV2 > expiryV1) {
                syncDuration = expiryV2 - expiryV1;
            }
            syncWrapper = owner != address(0) && wrappedExpiry < expiryV2 + _GRACE_PERIOD;
        }
    }

    /// @dev Determine if migratable.
    function _isMigratable(bytes32 node, uint32 fuses) internal view returns (bool) {
        if (LibMigration.isLocked(fuses)) {
            if ((fuses & CANNOT_TRANSFER) != 0) {
                return false;
            }
            if (
                (fuses & CANNOT_APPROVE) != 0 &&
                NAME_WRAPPER.getApproved(uint256(node)) != address(0)
            ) {
                return false; // FrozenTokenApproval
            }
        }
        return true;
    }
}
