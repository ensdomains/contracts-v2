// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {IBaseRegistrar} from "@ens/contracts/ethregistrar/IBaseRegistrar.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ERC165} from "@openzeppelin/contracts/utils/introspection/ERC165.sol";

import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {IETHSyncer} from "./interfaces/IETHSyncer.sol";

/// @notice `ETHRegistrarController.renew()` stub interface.
/// @dev Interface selector: `0xacf1a841`
interface IWrappedETHRegistrarController {
    /// @notice Renew an ENSv1 name.
    /// @param label The name to renew.
    /// @param duration The expiry extension, in seconds.
    function renew(string calldata label, uint256 duration) external payable;
}

/// @notice A mechanism for syncing ENSv2 with ENSv1.
contract ETHSyncer is Ownable, ERC165, IETHSyncer {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice ENSv1 `NameWrapper`.
    INameWrapper public immutable NAME_WRAPPER;

    /// @dev ENSv1 `BaseRegistrarImplementation`.
    IBaseRegistrar internal immutable _BASE_REGISTRAR;

    /// @notice ENSv1 `ETHRegistrarController` that is an active `NameWrapper` controller.
    IWrappedETHRegistrarController public immutable WRAPPED_CONTROLLER;

    /// @notice ENSv2 .eth `PermissionedRegistry`.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    /// @notice ENSv2 premigration bonus period, in seconds.
    uint64 public immutable BONUS_PERIOD;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the contract.
    /// @param owner_ Ownable owner.
    /// @param nameWrapper ENSv1 `NameWrapper` contract.
    /// @param wrappedController ENSv1 `ETHRegistrarController` that is a `NameWrapper` controller.
    /// @param ethRegistry ENSv2 .eth `PermissionedRegistry`.
    /// @param bonusPeriod ENSv2 premigration bonus period, in seconds.
    constructor(
        address owner_,
        INameWrapper nameWrapper,
        address wrappedController,
        IPermissionedRegistry ethRegistry,
        uint64 bonusPeriod
    ) Ownable(owner_) {
        NAME_WRAPPER = nameWrapper;
        _BASE_REGISTRAR = nameWrapper.registrar();
        WRAPPED_CONTROLLER = IWrappedETHRegistrarController(wrappedController);
        ETH_REGISTRY = ethRegistry;
        BONUS_PERIOD = bonusPeriod;
    }

    /// @inheritdoc ERC165
    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IETHSyncer).interfaceId || super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Transfers ownership of the registrar.
    /// @param newOwner The new owner for the registrar.
    function transferRegistrarOwnership(address newOwner) external onlyOwner {
        Ownable(address(_BASE_REGISTRAR)).transferOwnership(newOwner);
    }

    /// @inheritdoc IETHSyncer
    function syncRegistrar(string calldata label) external {
        uint256 tokenIdV1 = LibLabel.id(label);
        IPermissionedRegistry.State memory state = ETH_REGISTRY.getState(tokenIdV1);
        if (state.status != IPermissionedRegistry.Status.RESERVED) {
            revert NameNotReserved(label);
        }
        uint64 expiryV2 = state.expiry - BONUS_PERIOD;
        uint256 expiryV1 = _BASE_REGISTRAR.nameExpires(tokenIdV1);
        _BASE_REGISTRAR.renew(tokenIdV1, expiryV2 - expiryV1); // reverts if expired
    }

    /// @inheritdoc IETHSyncer
    function syncWrapper(string[] calldata labels) external {
        _BASE_REGISTRAR.addController(address(WRAPPED_CONTROLLER));
        for (uint256 i; i < labels.length; ++i) {
            WRAPPED_CONTROLLER.renew(labels[i], 0);
        }
        _BASE_REGISTRAR.removeController(address(WRAPPED_CONTROLLER));
    }
}
