// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {
    SafeERC20,
    IERC20
} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {
    EnhancedAccessControl
} from "../access-control/EnhancedAccessControl.sol";
import {InvalidOwner} from "../CommonErrors.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {
    IPermissionedRegistry
} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {IETHRegistrar} from "./interfaces/IETHRegistrar.sol";
import {IETHSyncer} from "./interfaces/IETHSyncer.sol";
import {IRentPriceOracle} from "./interfaces/IRentPriceOracle.sol";

/// @dev Composite role bitmap granted to name owners at registration — includes set-subregistry, set-resolver, and can-transfer (with admin variants).
uint256 constant REGISTRATION_ROLE_BITMAP = 0 |
    RegistryRolesLib.ROLE_SET_SUBREGISTRY |
    RegistryRolesLib.ROLE_SET_SUBREGISTRY_ADMIN |
    RegistryRolesLib.ROLE_SET_RESOLVER |
    RegistryRolesLib.ROLE_SET_RESOLVER_ADMIN |
    RegistryRolesLib.ROLE_CAN_TRANSFER_ADMIN;

/// @dev Root-level role authorizing oracle updates.
uint256 constant ROLE_SET_ORACLE = 1 << 0;
uint256 constant ROLE_SET_ORACLE_ADMIN = ROLE_SET_ORACLE << 128;

uint256 constant DEFAULT_ROLE_BITMAP = ROLE_SET_ORACLE | ROLE_SET_ORACLE_ADMIN;

/// @notice Commit-reveal registrar for .eth names. Registration requires two transactions: first
/// `commit(hash)` to record a commitment, then `register(...)` after the minimum commitment
/// age but before the maximum commitment age has elapsed. The commitment hash binds all
/// registration parameters (label, owner, secret, subregistry, resolver, duration, referrer)
/// to prevent front-running.
///
/// Delegates actual name storage to an `IPermissionedRegistry`, granting the owner a fixed
/// set of roles (set subregistry, set resolver, and transfer — each with their admin
/// counterpart).
///
/// Pricing and payment are delegated to a swappable `IRentPriceOracle`.
///
contract ETHRegistrar is EnhancedAccessControl, IETHRegistrar {
    ////////////////////////////////////////////////////////////////////////
    // Immutables
    ////////////////////////////////////////////////////////////////////////

    /// @notice ENSv2 .eth `PermissionedRegistry`.
    IPermissionedRegistry public immutable ETH_REGISTRY;

    /// @notice `ETHSyncer` contract.
    IETHSyncer public immutable ETH_SYNCER;

    /// @notice Address that receives payments.
    address public immutable BENEFICIARY;

    /// @notice Minimum seconds a commitment must age before registration can proceed.
    /// @dev If zero, front-running protection is disabled.
    uint64 public immutable MIN_COMMITMENT_AGE;

    /// @notice Maximum seconds a commitment remains valid; expired commitments are rejected.
    uint64 public immutable MAX_COMMITMENT_AGE;

    /// @inheritdoc IETHRegistrar
    uint64 public immutable GRACE_PERIOD;

    /// @notice Minimum register duration, in seconds.
    uint64 public immutable MIN_REGISTER_DURATION;

    /// @notice Minimum renew duration, in seconds.
    uint64 public immutable MIN_RENEW_DURATION;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Oracle for registration and renewal costs.
    IRentPriceOracle public rentPriceOracle;

    /// @inheritdoc IETHRegistrar
    mapping(bytes32 commitment => uint64 commitTime) public commitmentAt;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice `IRentPriceOracle` was replaced.
    /// @param oracle The new `IRentPriceOracle` contract.
    event RentPriceOracleUpdated(IRentPriceOracle oracle);

    ////////////////////////////////////////////////////////////////////////
    // Errors
    ////////////////////////////////////////////////////////////////////////

    /// @notice `maxCommitmentAge` was not greater than `minCommitmentAge`.
    /// @dev Error selector: `0x3e5aa838`
    error MaxCommitmentAgeTooLow();

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes the contract.
    /// @param hcaFactory HCA factory.
    /// @param ethRegistry ENSv2 .eth `PermissionedRegistry`.
    /// @param ethSyncer ETHSyncer contract.
    /// @param beneficiary Address that receives payments.
    /// @param minCommitmentAge Minimum seconds a commitment must age before registration can proceed.
    /// @param maxCommitmentAge Maximum seconds a commitment remains valid; expired commitments are rejected.
    /// @param gracePeriod Post-expiry period where still renewable and not available, in seconds.
    /// @param minRegisterDuration Minimum register duration, in seconds.
    /// @param minRenewDuration Minimum renew duration, in seconds.
    /// @param rentPriceOracle_ Initial oracle for registration and renewal costs.
    constructor(
        IHCAFactoryBasic hcaFactory,
        IPermissionedRegistry ethRegistry,
        IETHSyncer ethSyncer,
        address beneficiary,
        uint64 minCommitmentAge,
        uint64 maxCommitmentAge,
        uint64 gracePeriod,
        uint64 minRegisterDuration,
        uint64 minRenewDuration,
        IRentPriceOracle rentPriceOracle_
    ) HCAEquivalence(hcaFactory) {
        if (maxCommitmentAge <= minCommitmentAge) {
            revert MaxCommitmentAgeTooLow();
        }
        _grantRoles(ROOT_RESOURCE, DEFAULT_ROLE_BITMAP, _msgSender(), false);

        ETH_REGISTRY = ethRegistry;
        ETH_SYNCER = ethSyncer;
        BENEFICIARY = beneficiary;
        MIN_COMMITMENT_AGE = minCommitmentAge;
        MAX_COMMITMENT_AGE = maxCommitmentAge;
        GRACE_PERIOD = gracePeriod;
        MIN_REGISTER_DURATION = minRegisterDuration;
        MIN_RENEW_DURATION = minRenewDuration;

        rentPriceOracle = rentPriceOracle_;
        emit RentPriceOracleUpdated(rentPriceOracle_);
    }

    /// @inheritdoc EnhancedAccessControl
    function supportsInterface(
        bytes4 interfaceId
    ) public view override returns (bool) {
        return
            interfaceId == type(IETHRegistrar).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Change the rent price oracle.
    /// @param oracle The new `IRentPriceOracle` instance.
    function setRentPriceOracle(
        IRentPriceOracle oracle
    ) external onlyRootRoles(ROLE_SET_ORACLE) {
        rentPriceOracle = oracle;
        emit RentPriceOracleUpdated(oracle);
    }

    /// @inheritdoc IETHRegistrar
    function commit(bytes32 commitment) external {
        if (commitmentAt[commitment] + MAX_COMMITMENT_AGE > block.timestamp) {
            revert UnexpiredCommitmentExists(commitment);
        }
        commitmentAt[commitment] = uint64(block.timestamp);
        emit CommitmentMade(commitment);
    }

    /// @inheritdoc IETHRegistrar
    function register(
        string calldata label,
        address owner,
        bytes32 secret,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external returns (uint256 tokenId) {
        if (owner == address(0)) {
            revert InvalidOwner();
        }
        _consumeCommitment(
            makeCommitment(
                label,
                owner,
                secret,
                subregistry,
                resolver,
                duration,
                referrer
            )
        ); // reverts if no commitment
        IPermissionedRegistry.State memory state = _requireRegisterable(
            label,
            duration
        ); // reverts if not
        (uint256 base, uint256 premium) = rentPriceOracle.getRegisterPrice(
            label,
            _availablePeriod(state.expiry),
            duration,
            paymentToken
        ); // reverts if invalid
        SafeERC20.safeTransferFrom(
            paymentToken,
            _msgSender(),
            BENEFICIARY,
            base + premium
        ); // reverts if payment failed
        tokenId = ETH_REGISTRY.register(
            label,
            owner,
            subregistry,
            resolver,
            REGISTRATION_ROLE_BITMAP,
            uint64(block.timestamp) + duration // new expiry
        ); // should not revert
        emit NameRegistered(
            tokenId,
            label,
            owner,
            subregistry,
            resolver,
            duration,
            paymentToken,
            referrer,
            base,
            premium
        );
    }

    /// @inheritdoc IETHRegistrar
    function renew(
        string calldata label,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external {
        IPermissionedRegistry.State memory state = _requireRenewable(
            label,
            duration
        ); // reverts if not
        uint64 newExpiry = state.expiry + duration; // reverts if overflow
        uint256 amount = rentPriceOracle.getRenewPrice(
            label,
            state.expiry,
            duration,
            paymentToken
        ); // reverts if invalid
        SafeERC20.safeTransferFrom(
            paymentToken,
            _msgSender(),
            BENEFICIARY,
            amount
        ); // reverts if payment failed
        ETH_REGISTRY.renew(state.tokenId, newExpiry);
        emit NameRenewed(
            state.tokenId,
            label,
            duration,
            newExpiry,
            paymentToken,
            referrer,
            amount
        );
        if (_shouldSyncV1(state)) {
            ETH_SYNCER.syncRegistrar(label);
        }
    }

    /// @inheritdoc IETHRegistrar
    function isAvailable(string calldata label) external view returns (bool) {
        return _isAvailable(ETH_REGISTRY.getState(LibLabel.id(label)));
    }

    /// @inheritdoc IETHRegistrar
    function getRemainingGracePeriod(
        string calldata label
    ) external view returns (uint64) {
        IPermissionedRegistry.State memory state = ETH_REGISTRY.getState(
            LibLabel.id(label)
        );
        return
            uint64(
                _checkGrace(state, true)
                    ? GRACE_PERIOD - (block.timestamp - state.expiry)
                    : 0
            );
    }

    /// @inheritdoc IETHRegistrar
    function getRegisterPrice(
        string calldata label,
        uint64 duration,
        IERC20 paymentToken
    ) external view returns (uint256 bae, uint256 premium) {
        return
            rentPriceOracle.getRegisterPrice(
                label,
                _availablePeriod(_requireRegisterable(label, duration).expiry),
                duration,
                paymentToken
            );
    }

    /// @inheritdoc IETHRegistrar
    function getRenewPrice(
        string calldata label,
        uint64 duration,
        IERC20 paymentToken
    ) public view returns (uint256) {
        return
            rentPriceOracle.getRenewPrice(
                label,
                _requireRenewable(label, duration).expiry,
                duration,
                paymentToken
            );
    }

    /// @inheritdoc IETHRegistrar
    function makeCommitment(
        string calldata label,
        address owner,
        bytes32 secret,
        IRegistry subregistry,
        address resolver,
        uint64 duration,
        bytes32 referrer
    ) public pure override returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    label,
                    owner,
                    secret,
                    subregistry,
                    resolver,
                    duration,
                    referrer
                )
            );
    }

    ////////////////////////////////////////////////////////////////////////
    // Internal Functions
    ////////////////////////////////////////////////////////////////////////

    /// @dev Validates that the given `commitment` was recorded within the allowed time window
    ///      (between minimum and maximum commitment age), then deletes it so it cannot be reused.
    /// @param commitment The commitment hash to validate and consume.
    function _consumeCommitment(bytes32 commitment) internal {
        uint64 t = uint64(block.timestamp);
        uint64 t0 = commitmentAt[commitment];
        uint64 tMin = t0 + MIN_COMMITMENT_AGE;
        if (t < tMin) {
            revert CommitmentTooNew(commitment, tMin, t);
        }
        uint64 tMax = t0 + MAX_COMMITMENT_AGE;
        if (t >= tMax) {
            revert CommitmentTooOld(commitment, tMax, t);
        }
        delete commitmentAt[commitment];
    }

    /// @dev Ensure `label` is registerable.
    function _requireRegisterable(
        string calldata label,
        uint64 duration
    ) internal view returns (IPermissionedRegistry.State memory state) {
        state = ETH_REGISTRY.getState(LibLabel.id(label));
        if (!_isAvailable(state)) {
            revert NameNotRegisterable(label);
        }
        if (duration < MIN_REGISTER_DURATION) {
            revert DurationTooShort(duration, MIN_REGISTER_DURATION);
        }
    }

    /// @dev Ensure `label` is renewable.
    function _requireRenewable(
        string calldata label,
        uint64 duration
    ) internal view returns (IPermissionedRegistry.State memory state) {
        state = ETH_REGISTRY.getState(LibLabel.id(label));
        if (_isAvailable(state)) {
            revert NameNotRenewable(label);
        }
        if (duration < MIN_RENEW_DURATION) {
            revert DurationTooShort(duration, MIN_RENEW_DURATION);
        }
    }

    /// @dev Check if `AVAILABLE` and conditionally in grace.
    function _checkGrace(
        IPermissionedRegistry.State memory state,
        bool grace
    ) internal view returns (bool) {
        return
            state.status == IPermissionedRegistry.Status.AVAILABLE &&
            (grace ==
                (state.expiry > 0 &&
                    block.timestamp - state.expiry < GRACE_PERIOD));
    }

    /// @dev Determine if `AVAILABLE` and not in grace.
    function _isAvailable(
        IPermissionedRegistry.State memory state
    ) internal view returns (bool) {
        return _checkGrace(state, false);
    }

    /// @dev Determine if `RESERVED` or in grace was `RESERVED`.
    function _shouldSyncV1(
        IPermissionedRegistry.State memory state
    ) internal view returns (bool) {
        return
            state.status == IPermissionedRegistry.Status.RESERVED ||
            (_checkGrace(state, true) && state.latestOwner == address(0));
    }

    /// @dev Determine duration name has been available.
    function _availablePeriod(uint64 expiry) internal view returns (uint64) {
        uint64 t = uint64(block.timestamp);
        if (expiry == 0) {
            return t; // never registered
        }
        expiry += GRACE_PERIOD;
        return t > expiry ? t - expiry : 0;
    }
}
