// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    BaseRegistrarImplementation,
    IBaseRegistrar
} from "@ens/contracts/ethregistrar/BaseRegistrarImplementation.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {HCAContext} from "../hca/HCAContext.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {ETHRegistrar} from "../registrar/ETHRegistrar.sol";
import {INameRenewer} from "../registrar/interfaces/INameRenewer.sol";
import {IRentPriceOracle} from "../registrar/interfaces/IRentPriceOracle.sol";
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

/// @notice A mechanism to sync ENSv2 registrations with ENSv1.
contract ETHRenewerV1 is HCAContext, ERC165, INameRenewer {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice ENSv1 `NameWrapper`.
    INameWrapper public immutable NAME_WRAPPER;

    /// @notice ENSv1 `ETHRegistrarController` that is an active `NameWrapper` controller.
    IWrappedETHRegistrarController public immutable WRAPPED_CONTROLLER;

    /// @notice ENSv2 `ETHRegistrar`.
    ETHRegistrar public immutable ETH_REGISTRAR;

    /// @dev ENSv2 .eth `PermissionedRegistry`.
    IPermissionedRegistry internal immutable _ETH_REGISTRY;

    /// @dev ENSv1 `BaseRegistrarImplementation` contract.
    IBaseRegistrar internal immutable _BASE_REGISTRAR;

    /// @dev Same as `BaseRegistrarImplementation.GRACE_PERIOD()`.
    uint64 internal immutable _GRACE_PERIOD_V1;

    /// @dev Same as `ETH_REGISTRAR.GRACE_PERIOD()`.
    uint64 internal immutable _GRACE_PERIOD_V2;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes WrapperRenewerV1.
    /// @param hcaFactory The HCA factory.
    /// @param nameWrapper The ENSv1 `NameWrapper` contract.
    /// @param wrappedController ENSv1 `ETHRegistrarController` that is a `NameWrapper` controller.
    /// @param ethRegistrar ENSv2 `ETHRegistrar`.
    constructor(
        IHCAFactoryBasic hcaFactory,
        INameWrapper nameWrapper,
        address wrappedController,
        ETHRegistrar ethRegistrar
    ) HCAEquivalence(hcaFactory) {
        NAME_WRAPPER = nameWrapper;
        _BASE_REGISTRAR = nameWrapper.registrar();
        _GRACE_PERIOD_V1 = uint64(
            BaseRegistrarImplementation(address(_BASE_REGISTRAR)).GRACE_PERIOD()
        );
        WRAPPED_CONTROLLER = IWrappedETHRegistrarController(wrappedController);
        ETH_REGISTRAR = ethRegistrar;
        _ETH_REGISTRY = ethRegistrar.ETH_REGISTRY();
        _GRACE_PERIOD_V2 = ETH_REGISTRAR.GRACE_PERIOD();
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return
            interfaceId == type(INameRenewer).interfaceId || super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @inheritdoc INameRenewer
    function renew(
        string calldata label,
        uint64 duration,
        address paymentToken,
        bytes32 referrer
    ) external payable {
        uint256 tokenIdV1 = LibLabel.id(label);
        IPermissionedRegistry.State memory state = _ETH_REGISTRY.getState(tokenIdV1);
        if (!_isRenewable(state)) {
            revert NameNotRenewable(label);
        }
        uint64 expiry = state.expiry + duration; // reverts if overflow
        IRentPriceOracle oracle = ETH_REGISTRAR.rentPriceOracle();
        uint256 amount = oracle.getRenewPrice(label, state.expiry, duration, paymentToken); // reverts if invalid
        oracle.pay{value: msg.value}(_msgSender(), paymentToken, amount); // reverts if payment failed
        _ETH_REGISTRY.renew(tokenIdV1, expiry); // should not revert
        _BASE_REGISTRAR.renew(tokenIdV1, duration); // invariant: always in sync
        emit NameRenewed(state.tokenId, label, duration, expiry, paymentToken, referrer, amount);
    }

    /// @notice Sync `NameWrapper` expiry.
    /// @param labels The labels to sync.
    function syncWrapper(string[] calldata labels) external {
        _BASE_REGISTRAR.addController(address(WRAPPED_CONTROLLER));
        for (uint256 i; i < labels.length; ++i) {
            WRAPPED_CONTROLLER.renew(labels[i], 0);
        }
        _BASE_REGISTRAR.removeController(address(WRAPPED_CONTROLLER));
    }

    /// @inheritdoc INameRenewer
    function isRenewable(string memory label) external view returns (bool) {
        return _isRenewable(_ETH_REGISTRY.getState(LibLabel.id(label)));
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Check if `RESERVED` or previously `RESERVED` and in grace.
    function _isRenewable(IPermissionedRegistry.State memory state) internal view returns (bool) {
        return
            state.status == IPermissionedRegistry.Status.RESERVED ||
            (state.status == IPermissionedRegistry.Status.AVAILABLE &&
                state.latestOwner == address(0) &&
                block.timestamp - state.expiry < _GRACE_PERIOD_V2);
    }
}
