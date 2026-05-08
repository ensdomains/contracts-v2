// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    BaseRegistrarImplementation
} from "@ens/contracts/ethregistrar/BaseRegistrarImplementation.sol";

import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {AbstractETHRegistrar} from "./AbstractETHRegistrar.sol";
import {IETHRenewer} from "./interfaces/IETHRenewer.sol";
import {IRentPriceOracle} from "./interfaces/IRentPriceOracle.sol";

/// @notice `ETHRegistrarController.renew()` stub interface.
/// @dev Interface selector: `0xacf1a841`
interface IWrappedETHRegistrarController {
    /// @notice Renew an ENSv1 name.
    /// @param label The name to renew.
    /// @param duration The expiry extension, in seconds.
    function renew(string calldata label, uint256 duration) external payable;
}


/// @notice .eth registrar that only renews premigrated ENSv2 reservations
/// and syncs with ENSv1.
///
/// Pricing and payment are delegated to a swappable `IRentPriceOracle`.
///
/// Provides a mechanism for syncing `NameWrapper` expiry.
///
contract ETHRenewerV1 is AbstractETHRegistrar {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc IETHRenewer
    uint64 public immutable GRACE_PERIOD;

    /// @dev ENSv2 `GRACE_PERIOD`.
    uint64 internal immutable _GRACE_PERIOD_V2;

    /// @notice ENSv1 `BaseRegistrarImplementation` contract.
    BaseRegistrarImplementation public immutable BASE_REGISTRAR;

    /// @notice ENSv1 `ETHRegistrarController` that is an active `NameWrapper` controller.
    IWrappedETHRegistrarController public immutable WRAPPED_CONTROLLER;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the contract.
    /// @param owner_ Contract owner.
    /// @param hcaFactory HCA factory.
    /// @param ethRegistry ENSv2 .eth `PermissionedRegistry`.
    /// @param beneficiary Address that receives payments.
    /// @param oracle Initial oracle for registration and renewal costs.
    /// @param gracePeriod Post-expiry period where renewable and not available, in seconds.
    /// @param bonusPeriod Duration added by premigration, in seconds.
    /// @param baseRegistrar ENSv1 `BaseRegistrarImplementation` contract.
    /// @param wrappedController ENSv1 `ETHRegistrarController` that is a `NameWrapper` controller.
    constructor(
        address owner_,
        IHCAFactoryBasic hcaFactory,
        IPermissionedRegistry ethRegistry,
        address beneficiary,
        IRentPriceOracle oracle,
        uint64 gracePeriod,
        uint64 bonusPeriod,
        BaseRegistrarImplementation baseRegistrar,
        address wrappedController
    )
        AbstractETHRegistrar(owner_, hcaFactory, ethRegistry, beneficiary, oracle)
    {
        GRACE_PERIOD = bonusPeriod + gracePeriod;
        _GRACE_PERIOD_V2 = gracePeriod;
        BASE_REGISTRAR = baseRegistrar;
        WRAPPED_CONTROLLER = IWrappedETHRegistrarController(wrappedController);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Transfers ownership of the registrar.
    /// @param newOwner The new owner for the registrar.
    function transferRegistrarOwnership(address newOwner) external onlyOwner {
        BASE_REGISTRAR.transferOwnership(newOwner);
    }

    /// @notice Sync `NameWrapper` expiry with `BaseRegistrarImplementation` expiry.
    /// @param labels The labels to sync.
    function syncWrapper(string[] calldata labels) external {
        BASE_REGISTRAR.addController(address(WRAPPED_CONTROLLER));
        for (uint256 i; i < labels.length; ++i) {
            WRAPPED_CONTROLLER.renew(labels[i], 0);
        }
        BASE_REGISTRAR.removeController(address(WRAPPED_CONTROLLER));
    }

    /// @inheritdoc IETHRenewer
    function getRemainingGracePeriod(string calldata label) external view returns (uint64) {
        IPermissionedRegistry.State memory state = ETH_REGISTRY.getState(LibLabel.id(label));
        uint64 bonusPeriod = GRACE_PERIOD - _GRACE_PERIOD_V2;
        if (state.latestOwner == address(0) && state.expiry > bonusPeriod) {
            uint64 expiryV1 = state.expiry - bonusPeriod;
            uint64 t = uint64(block.timestamp);
            if (t >= expiryV1 && t < expiryV1 + GRACE_PERIOD) {
                return GRACE_PERIOD - (t - expiryV1);
            }
        }
        return 0;
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Update ENSv1 during renew.
    function _onRenew(string calldata label, uint64 duration) internal override {
        BASE_REGISTRAR.renew(LibLabel.id(label), duration);
    }

    /// @dev Determine if `RESERVED` or in grace was `RESERVED`.
    function _isRenewable(IPermissionedRegistry.State memory state)
        internal
        view
        override
        returns (bool)
    {
        return
            state.status == IPermissionedRegistry.Status.RESERVED ||
            (state.status == IPermissionedRegistry.Status.AVAILABLE &&
                state.latestOwner == address(0) &&
                (block.timestamp - state.expiry) < _GRACE_PERIOD_V2);
    }
}
