// SPDX-License-Identifier: MIT
pragma solidity >=0.8.13;

import {SafeERC20, IERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

import {EnhancedAccessControl} from "../access-control/EnhancedAccessControl.sol";
import {EACBaseRolesLib} from "../access-control/libraries/EACBaseRolesLib.sol";
import {InvalidOwner} from "../CommonErrors.sol";
import {HCAEquivalence} from "../hca/HCAEquivalence.sol";
import {IHCAFactoryBasic} from "../hca/interfaces/IHCAFactoryBasic.sol";
import {IPermissionedRegistry} from "../registry/interfaces/IPermissionedRegistry.sol";
import {IRegistry} from "../registry/interfaces/IRegistry.sol";
import {RegistryRolesLib} from "../registry/libraries/RegistryRolesLib.sol";
import {LibLabel} from "../utils/LibLabel.sol";

import {IETHRegistrar} from "./interfaces/IETHRegistrar.sol";
import {IPaymentTokenOracle} from "./interfaces/IPaymentTokenOracle.sol";
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
/// Payment is collected via ERC20 `safeTransferFrom` to an immutable beneficiary address.
/// Pricing is delegated to a swappable `IRentPriceOracle`. Renewals pay only the base rate;
/// registrations pay base + premium (for recently expired names).
///
contract ETHRegistrar is IETHRegistrar, EnhancedAccessControl {
    ////////////////////////////////////////////////////////////////////////
    // Constants
    ////////////////////////////////////////////////////////////////////////

    /// @notice The permissioned registry where .eth names are stored and managed.
    IPermissionedRegistry public immutable REGISTRY;

    /// @notice Address that receives all registration and renewal payments.
    address public immutable BENEFICIARY;

    /// @notice Minimum seconds a commitment must age before registration can proceed.
    uint64 public immutable MIN_COMMITMENT_AGE;

    /// @notice Maximum seconds a commitment remains valid; expired commitments are rejected.
    uint64 public immutable MAX_COMMITMENT_AGE;

    /// @notice Shortest allowed registration duration, in seconds.
    uint64 public immutable MIN_REGISTER_DURATION;

    /// @notice Shortest allowed renew duration, in seconds.
    uint64 public immutable MIN_RENEW_DURATION;

    /// @notice Post-expiry period where a name can be revived and is not registerable.
    uint64 public immutable GRACE_PERIOD;

    ////////////////////////////////////////////////////////////////////////
    // Storage
    ////////////////////////////////////////////////////////////////////////

    /// @notice Pricing oracle used for computing registration and renewal costs.
    IRentPriceOracle public rentPriceOracle;

    /// @inheritdoc IETHRegistrar
    mapping(bytes32 commitment => uint64 commitTime) public commitmentAt;

    ////////////////////////////////////////////////////////////////////////
    // Events
    ////////////////////////////////////////////////////////////////////////

    /// @notice Emitted when the rent price oracle is replaced.
    /// @param oracle The new `IRentPriceOracle` contract.
    event RentPriceOracleChanged(IRentPriceOracle oracle);

    ////////////////////////////////////////////////////////////////////////
    // Initialization
    ////////////////////////////////////////////////////////////////////////

    /// @notice Initializes ETHRegistrar.
    /// @param registry The permissioned registry where .eth names are stored and managed.
    /// @param hcaFactory The HCA factory.
    /// @param beneficiary The address that receives all registration and renewal payments.
    /// @param minCommitmentAge The minimum seconds a commitment must age before registration can proceed.
    /// @param maxCommitmentAge The maximum seconds a commitment remains valid; expired commitments are rejected.
    /// @param minRegisterDuration The shortest allowed registration duration, in seconds.
    /// @param minRenewDuration The shortest allowed renew duration, in seconds.
    /// @param gracePeriod The post-expiry period where a name can be revived and is not registerable.
    /// @param rentPriceOracle_ The initial pricing oracle used for computing registration and renewal costs.
    constructor(
        IPermissionedRegistry registry,
        IHCAFactoryBasic hcaFactory,
        address beneficiary,
        uint64 minCommitmentAge,
        uint64 maxCommitmentAge,
        uint64 minRegisterDuration,
        uint64 minRenewDuration,
        uint64 gracePeriod,
        IRentPriceOracle rentPriceOracle_
    ) HCAEquivalence(hcaFactory) {
        if (maxCommitmentAge <= minCommitmentAge) {
            revert MaxCommitmentAgeTooLow();
        }
        _grantRoles(ROOT_RESOURCE, EACBaseRolesLib.ALL_ROLES, _msgSender(), true);

        REGISTRY = registry;
        BENEFICIARY = beneficiary;
        MIN_COMMITMENT_AGE = minCommitmentAge;
        MAX_COMMITMENT_AGE = maxCommitmentAge;
        MIN_REGISTER_DURATION = minRegisterDuration;
        MIN_RENEW_DURATION = minRenewDuration;
        GRACE_PERIOD = gracePeriod;

        rentPriceOracle = rentPriceOracle_;
        emit RentPriceOracleChanged(rentPriceOracle_);
    }

    /// @inheritdoc EnhancedAccessControl
    function supportsInterface(
        bytes4 interfaceId
    ) public view override(EnhancedAccessControl) returns (bool) {
        return
            interfaceId == type(IETHRegistrar).interfaceId ||
            interfaceId == type(IPaymentTokenOracle).interfaceId ||
            super.supportsInterface(interfaceId);
    }

    ////////////////////////////////////////////////////////////////////////
    // Implementation
    ////////////////////////////////////////////////////////////////////////

    /// @notice Change the rent price oracle.
    /// @param oracle The new `IRentPriceOracle` contract.
    function setRentPriceOracle(IRentPriceOracle oracle) external onlyRootRoles(ROLE_SET_ORACLE) {
        rentPriceOracle = oracle;
        emit RentPriceOracleChanged(oracle);
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
    ) external returns (uint256) {
        if (owner == address(0)) {
            revert InvalidOwner();
        }
        _consumeCommitment(
            makeCommitment(label, owner, secret, subregistry, resolver, duration, referrer)
        ); // reverts if no commitment
        (uint256 tokenId, uint64 expiry, uint256 base, uint256 premium) = rentPrice(
            label,
            duration,
            paymentToken
        );
        if (tokenId > 0 || base == 0) {
            revert CannotRegister(); // registered/reserved OR no price
        }
        SafeERC20.safeTransferFrom(paymentToken, _msgSender(), BENEFICIARY, base + premium); // reverts if payment failed
        tokenId = REGISTRY.register(
            label,
            owner,
            subregistry,
            resolver,
            REGISTRATION_ROLE_BITMAP,
            expiry
        ); // reverts if not available
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
        return tokenId;
    }

    /// @inheritdoc IETHRegistrar
    function renew(
        string calldata label,
        uint64 duration,
        IERC20 paymentToken,
        bytes32 referrer
    ) external {
        (uint256 tokenId, uint64 expiry, uint256 base, ) = rentPrice(label, duration, paymentToken);
        if (tokenId == 0 || base == 0) {
            revert CannotRenew(); // expired + grace OR no price
        }
        SafeERC20.safeTransferFrom(paymentToken, _msgSender(), BENEFICIARY, base); // reverts if payment failed
        REGISTRY.renew(tokenId, expiry);
        emit NameRenewed(tokenId, label, duration, expiry, paymentToken, referrer, base);
    }

    /// @inheritdoc IPaymentTokenOracle
    function isPaymentToken(IERC20 paymentToken) external view returns (bool) {
        return rentPriceOracle.isPaymentToken(paymentToken);
    }

    /// @notice Check if `label` is in grace.
    /// @param label The name to check.
    /// @return The remaining grace period time, in seconds, or 0 if not in grace.
    function getRemainingGracePeriod(string calldata label) external view returns (uint64) {
        IPermissionedRegistry.State memory state = REGISTRY.getState(LibLabel.id(label));
        return
            state.status == IPermissionedRegistry.Status.AVAILABLE && !_isAvailable(state)
                ? GRACE_PERIOD - (uint64(block.timestamp) - state.expiry)
                : uint64(0);
    }

    /// @notice Check if a `label` is valid.
    /// @param label The name to check.
    /// @return `true` if the `label` is valid.
    function isValid(string calldata label) external view returns (bool) {
        (uint256 base, ) = rentPriceOracle.registerPrice(label, 0, 1, IERC20(address(0)));
        return base > 0;
    }

    /// @inheritdoc IETHRegistrar
    /// @dev Does not check if normalized or valid.
    function isAvailable(string calldata label) external view returns (bool) {
        return _isAvailable(REGISTRY.getState(LibLabel.id(label)));
    }

    /// @inheritdoc IETHRegistrar
    function rentPrice(
        string memory label,
        uint64 duration,
        IERC20 paymentToken
    ) public view returns (uint256 tokenId, uint64 expiry, uint256 base, uint256 premium) {
        if (!rentPriceOracle.isPaymentToken(paymentToken)) {
            revert PaymentTokenNotSupported(paymentToken);
        }
        uint64 t = uint64(block.timestamp);
        IPermissionedRegistry.State memory state = REGISTRY.getState(LibLabel.id(label));
        if (_isAvailable(state)) {
            if (duration < MIN_REGISTER_DURATION) {
                revert DurationTooShort(duration, MIN_REGISTER_DURATION);
            }
            uint64 since = t - state.expiry; // time since expiry
            since = since > GRACE_PERIOD ? since - GRACE_PERIOD : 0; // time since grace ended
            (base, premium) = rentPriceOracle.registerPrice(label, since, duration, paymentToken);
            expiry = t + duration;
        } else {
            if (duration < MIN_RENEW_DURATION) {
                revert DurationTooShort(duration, MIN_RENEW_DURATION);
            }
            expiry = state.expiry;
            uint64 remaining;
            uint64 baseExtension;
            if (expiry > t) {
                remaining = expiry - t;
            } else {
                baseExtension = t - expiry; // grace debt
                duration = duration > baseExtension ? duration - baseExtension : 0; // reduced extension
            }
            expiry = t + remaining + duration;
            base = rentPriceOracle.renewPrice(
                label,
                remaining,
                baseExtension,
                duration,
                paymentToken
            );
            tokenId = state.tokenId;
        }
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
    ) public pure returns (bytes32) {
        return
            keccak256(abi.encode(label, owner, secret, subregistry, resolver, duration, referrer));
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

    /// @dev Check if `label` is available for registration.
    /// @param state The current registry state.
    /// @return `true` if available for registration.
    function _isAvailable(IPermissionedRegistry.State memory state) internal view returns (bool) {
        return
            state.status == IPermissionedRegistry.Status.AVAILABLE &&
            (state.expiry == 0 || block.timestamp - state.expiry >= GRACE_PERIOD);
    }
}
