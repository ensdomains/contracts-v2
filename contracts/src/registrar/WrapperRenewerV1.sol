// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

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

/// @notice A renewal mechanism for unmigratable ENSv1 .eth 2LD names.
///
/// To renew:
/// * must be Locked .eth 2LD (NameWrapper w/CANNOT_UNLOCK burned)
/// * must have at least one of:
///      - CANNOT_TRANSFER burned
///      - CANNOT_APPROVE burned w/non-null getApproved()
///
contract WrapperRenewerV1 {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv1 `NameWrapper` contract that holds wrapped names as ERC1155 tokens.
    INameWrapper public immutable NAME_WRAPPER;

    /// @notice The ENSv1 `ETHRegistrarController` that is a `NameWrapper` controller.
    IWrappedETHRegistrarController public immutable WRAPPED_CONTROLLER;

    /// @notice The ENSv2 .eth `PermissionedRegistry` where migrated names are registered.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _REGISTRAR_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes WrapperRenewerV1.
    /// @param nameWrapper The ENSv1 `NameWrapper` contract.
    /// @param wrappedController The ENSv1 `ETHRegistrarController` that is a `NameWrapper` controller.
    /// @param ethRegistry The ENSv2 .eth `PermissionedRegistry` where migrated name
    constructor(
        INameWrapper nameWrapper,
        address wrappedController,
        IPermissionedRegistry ethRegistry
    ) {
        NAME_WRAPPER = nameWrapper;
        WRAPPED_CONTROLLER = IWrappedETHRegistrarController(wrappedController);
        ETH_REGISTRY = ethRegistry;
        _REGISTRAR_V1 = nameWrapper.registrar();
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Overpayment from `WRAPPED_CONTROLLER.renew()`.
    receive() external payable {}

    /// @notice Renew an unmigratable ENSv1 .eth 2LD.
    /// @param label The name to renew.
    /// @param duration The expiry extension, in seconds.
    function renew(string calldata label, uint64 duration) external payable {
        uint256 labelId = LibLabel.id(label);

        // ensure unmigratable
        if (_isMigratable(bytes32(labelId))) {
            revert LibMigration.NameRequiresMigration();
        }

        // ensure RESERVED
        // TODO: use v2 grace logic
        IPermissionedRegistry.State memory state = ETH_REGISTRY.getState(labelId);
        require(state.status == IPermissionedRegistry.Status.RESERVED);

        // TODO: v2 pricing logic in eth
        uint256 over = 0;

        // renew v1
        _REGISTRAR_V1.addController(address(WRAPPED_CONTROLLER));
        WRAPPED_CONTROLLER.renew{value: msg.value}(label, duration);
        _REGISTRAR_V1.removeController(address(WRAPPED_CONTROLLER));

        // renew v2
        ETH_REGISTRY.renew(labelId, state.expiry + duration);

        // refund
        if (over > 0) {
            (bool ok, ) = msg.sender.call{value: over}("");
            require(ok);
        }
    }

    /// @notice Check if `label` is renewable.
    /// @param label The label to check.
    /// @return `true` if `label` is renewable.
    function canRenew(string calldata label) external view returns (bool) {
        return !_isMigratable(bytes32(LibLabel.id(label)));
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Determine if .eth 2LD is migratable.
    function _isMigratable(bytes32 labelHash) internal view returns (bool) {
        bytes32 node = NameCoder.namehash(NameCoder.ETH_NODE, labelHash);
        (, uint32 fuses, ) = NAME_WRAPPER.getData(uint256(node));
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
