// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    BaseRegistrarImplementation,
    IBaseRegistrar
} from "@ens/contracts/ethregistrar/BaseRegistrarImplementation.sol";
import {NameCoder} from "@ens/contracts/utils/NameCoder.sol";
import {INameWrapper} from "@ens/contracts/wrapper/INameWrapper.sol";

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
contract ETHRenewerV1 {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The ENSv1 `NameWrapper` contract that holds wrapped names as ERC1155 tokens.
    INameWrapper public immutable NAME_WRAPPER;

    /// @notice The ENSv1 `ETHRegistrarController` that is a `NameWrapper` controller.
    IWrappedETHRegistrarController public immutable WRAPPED_CONTROLLER;

    /// @notice The ENSv2 .eth `PermissionedRegistry`.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    /// @notice Same as `BaseRegistrarImplementation.GRACE_PERIOD()`.
    uint64 public immutable GRACE_PERIOD;

    /// @dev The ENSv1 `BaseRegistrar` contract.
    IBaseRegistrar internal immutable _REGISTRAR_V1;

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes WrapperRenewerV1.
    /// @param nameWrapper The ENSv1 `NameWrapper` contract.
    /// @param wrappedController The ENSv1 `ETHRegistrarController` that is a `NameWrapper` controller.
    /// @param ethRegistry The ENSv2 .eth `PermissionedRegistry`.
    constructor(
        INameWrapper nameWrapper,
        address wrappedController,
        IPermissionedRegistry ethRegistry
    ) {
        NAME_WRAPPER = nameWrapper;
        WRAPPED_CONTROLLER = IWrappedETHRegistrarController(wrappedController);
        ETH_REGISTRY = ethRegistry;
        _REGISTRAR_V1 = nameWrapper.registrar();
        GRACE_PERIOD = uint64(BaseRegistrarImplementation(address(_REGISTRAR_V1)).GRACE_PERIOD());
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
            (uint64 syncDuration, bool syncWrapper) = getState(tokenIdV1);
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
        (uint64 syncDuration, bool syncWrapper) = getState(LibLabel.id(label));
        return syncDuration > 0 || syncWrapper;
    }

    /// @notice Determine sync parameters.
    /// @param tokenIdV1 The labelhash to sync.
    /// @return syncDuration The ENSv1 registration extension, in seconds.
    /// @return syncWrapper `true` if NameWrapper expiry requires updating.
    function getState(
        uint256 tokenIdV1
    ) public view returns (uint64 syncDuration, bool syncWrapper) {
        IPermissionedRegistry.State memory state = ETH_REGISTRY.getState(tokenIdV1);
        if (state.status == IPermissionedRegistry.Status.RESERVED) {
            uint64 expiryV2 = state.expiry - GRACE_PERIOD; // remove bonus
            uint64 expiryV1 = uint64(_REGISTRAR_V1.nameExpires(tokenIdV1));
            // same as: !BaseRegistrar.available()
            if (expiryV1 + GRACE_PERIOD >= block.timestamp) {
                if (expiryV2 > expiryV1) {
                    syncDuration = expiryV2 - expiryV1;
                }
                if (NAME_WRAPPER.isWrapped(NameCoder.ETH_NODE, bytes32(tokenIdV1))) {
                    (, , uint64 wrappedExpiry) = NAME_WRAPPER.getData(
                        uint256(NameCoder.namehash(NameCoder.ETH_NODE, bytes32(tokenIdV1)))
                    );
                    // wrapper expiry contains grace
                    // see: V1Fixture.t.sol: `test_nameWrapper_expiryForETH2LDIncludesGrace()`.
                    syncWrapper = wrappedExpiry < expiryV2 + GRACE_PERIOD;
                }
            }
        }
    }
}
